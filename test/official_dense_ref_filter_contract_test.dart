import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

({int centerByte, double sum, double squaredSum}) _officialFilterOracle({
  required List<int> image,
  required int width,
  required int height,
  required int row,
  required int col,
  required int windowRadius,
  required int windowStep,
  required double sigmaSpatial,
  required double sigmaColor,
}) {
  double sample(int sampleRow, int sampleCol) {
    if (sampleRow < 0 ||
        sampleRow >= height ||
        sampleCol < 0 ||
        sampleCol >= width) {
      return 0;
    }
    return image[sampleRow * width + sampleCol] / 255.0;
  }

  final spatialNormalization = 1.0 / (2.0 * sigmaSpatial * sigmaSpatial);
  final colorNormalization = 1.0 / (2.0 * sigmaColor * sigmaColor);
  final centerColor = sample(row, col);

  var colorSum = 0.0;
  var colorSquaredSum = 0.0;
  var bilateralWeightSum = 0.0;
  for (var windowRow = -windowRadius;
      windowRow <= windowRadius;
      windowRow += windowStep) {
    for (var windowCol = -windowRadius;
        windowCol <= windowRadius;
        windowCol += windowStep) {
      final color = sample(row + windowRow, col + windowCol);
      final spatialDistSquared =
          windowRow * windowRow + windowCol * windowCol;
      final colorDist = centerColor - color;
      final weight = math.exp(
        -spatialDistSquared * spatialNormalization -
            colorDist * colorDist * colorNormalization,
      );
      colorSum += weight * color;
      colorSquaredSum += weight * color * color;
      bilateralWeightSum += weight;
    }
  }

  colorSum /= bilateralWeightSum;
  colorSquaredSum /= bilateralWeightSum;
  return (
    centerByte: (255.0 * centerColor).truncate(),
    sum: colorSum,
    squaredSum: colorSquaredSum,
  );
}

void main() {
  const root = 'vendor/official_dense/ref_filter';
  const shaderPath = '$root/filter_u8.comp';

  test('reference filter is a literal COLMAP 4.1.1 CUDA translation', () {
    final source = File(shaderPath).readAsStringSync();

    expect(source, contains('COLMAP 4.1.1 a0d785f'));
    expect(
      source,
      contains(
        'gpu_mat_ref_image.cu sha256 '
        '01bf74693da801cce20411a447a673b7b2577f028590130264fa1659bc2d8142',
      ),
    );
    expect(
      source,
      contains('local_size_x = 16, local_size_y = 8, local_size_z = 1'),
    );
    expect(source, contains('int row = int(gl_GlobalInvocationID.y)'));
    expect(source, contains('int col = int(gl_GlobalInvocationID.x)'));
    expect(source, contains('return 0.0; // cudaAddressModeBorder'));
    expect(source, contains('image_out.values[index] = uint(255.0 * center_color)'));
    expect(source, contains('color_sum += bilateral_weight * color'));
    expect(source, contains('color_squared_sum += bilateral_weight * color * color'));
    expect(source, contains('color_sum /= bilateral_weight_sum'));
    expect(source, contains('color_squared_sum /= bilateral_weight_sum'));
    expect(source, isNot(contains('epsilon')));
    expect(source, isNot(contains('clamp(')));
  });

  test('CPU oracle fixes row-major indexing, border zero, and formula order', () {
    const image = <int>[
      0,
      64,
      128,
      255,
    ];
    final output = _officialFilterOracle(
      image: image,
      width: 2,
      height: 2,
      row: 0,
      col: 1,
      windowRadius: 1,
      windowStep: 1,
      sigmaSpatial: 2,
      sigmaColor: 0.5,
    );

    expect(output.centerByte, 64);
    expect(output.sum, closeTo(0.13866110904060497, 1e-15));
    expect(output.squaredSum, closeTo(0.08218418598377207, 1e-15));
  });

  test('shader compiles for Vulkan 1.1 and validates as SPIR-V', () {
    final temp = Directory.systemTemp.createTempSync('pw-ref-filter-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final spv = '${temp.path}/filter_u8.spv';

    final compile = Process.runSync('glslangValidator', <String>[
      '-V',
      '--target-env',
      'vulkan1.1',
      '-o',
      spv,
      shaderPath,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}${compile.stderr}');

    final validate = Process.runSync('spirv-val', <String>[
      '--target-env',
      'vulkan1.1',
      spv,
    ]);
    expect(
      validate.exitCode,
      0,
      reason: '${validate.stdout}${validate.stderr}',
    );
  });

  test('reference filter module contains no Swift', () {
    final swiftFiles = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'))
        .toList();
    expect(swiftFiles, isEmpty);
  });
}
