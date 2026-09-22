import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<double> _rotateCounterClockwise(
  List<double> input,
  int width,
  int height,
) {
  final output = List<double>.filled(width * height, 0);
  for (var inputY = 0; inputY < height; inputY++) {
    for (var inputX = 0; inputX < width; inputX++) {
      final outputX = inputY;
      final outputY = width - 1 - inputX;
      output[outputY * height + outputX] = input[inputY * width + inputX];
    }
  }
  return output;
}

List<double> _flipHorizontal(List<double> input, int width, int height) {
  final output = List<double>.filled(width * height, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      output[y * width + (width - 1 - x)] = input[y * width + x];
    }
  }
  return output;
}

List<double> _transpose(List<double> input, int width, int height) {
  final output = List<double>.filled(width * height, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      output[x * height + y] = input[y * width + x];
    }
  }
  return output;
}

void main() {
  const shaderRoot = 'vendor/official_dense/mat_ops';

  test(
    'matrix-operation shaders preserve the 32x32 tile within 128 invocations',
    () {
      final rotate = File('$shaderRoot/rotate_f32.comp').readAsStringSync();
      final flip = File(
        '$shaderRoot/flip_horizontal_f32.comp',
      ).readAsStringSync();
      final transpose = File(
        '$shaderRoot/transpose_f32.comp',
      ).readAsStringSync();

      expect(
        rotate,
        contains('local_size_x = 32, local_size_y = 1, local_size_z = 1'),
      );
      expect(
        flip,
        contains('local_size_x = 16, local_size_y = 8, local_size_z = 1'),
      );
      expect(
        transpose,
        contains('local_size_x = 16, local_size_y = 8, local_size_z = 1'),
      );
      expect(flip, contains('shared float tile[32][33]'));
      expect(transpose, contains('shared float tile[32][33]'));
    },
  );

  test('shaders retain official byte-pitch and edge-clamp semantics', () {
    for (final name in <String>[
      'rotate_f32.comp',
      'flip_horizontal_f32.comp',
      'transpose_f32.comp',
    ]) {
      final source = File('$shaderRoot/$name').readAsStringSync();
      expect(source, contains('input_pitch_bytes'));
      expect(source, contains('output_pitch_bytes'));
      expect(source, contains('>> 2'));
      expect(source, contains('COLMAP 4.1.1 a0d785f'));
    }

    final flip = File(
      '$shaderRoot/flip_horizontal_f32.comp',
    ).readAsStringSync();
    final transpose = File('$shaderRoot/transpose_f32.comp').readAsStringSync();
    for (final source in <String>[flip, transpose]) {
      expect(source, contains('thread_x + column_pass * 16'));
      expect(source, contains('min(thread_y, pc.height - 1 - block_y * 32)'));
      expect(source, contains('min(x_index, pc.width - 1)'));
      expect(source, contains('min(y_index, pc.height - i - 1)'));
      expect(source, contains('barrier()'));
    }
  });

  test('2x3 CPU oracle fixes rotation, flip, and transpose orientation', () {
    const input = <double>[1, 2, 3, 4, 5, 6];

    expect(_rotateCounterClockwise(input, 2, 3), <double>[2, 4, 6, 1, 3, 5]);
    expect(_flipHorizontal(input, 2, 3), <double>[2, 1, 4, 3, 6, 5]);
    expect(_transpose(input, 2, 3), <double>[1, 3, 5, 2, 4, 6]);
  });

  test('new matrix-operation module contains no Swift', () {
    final swiftFiles = Directory(shaderRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'))
        .toList();

    expect(swiftFiles, isEmpty);
  });
}
