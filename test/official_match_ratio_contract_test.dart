import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_aether_sfm_ffi.dart';

void main() {
  final pocketWorld = Directory.current;
  final officialPipeline = Directory(
    '${pocketWorld.parent.path}/Aether3D-cross/aether_cpp/official_pipeline',
  );

  test('official phone route selects Lowe ratio 0.8', () {
    expect(AetherSfmStreamSession.defaultMatchMaxRatio, 0.8);
  });

  test('official native Metal and CPU fallbacks stay on ratio 0.8', () {
    final core = File(
      '${officialPipeline.path}/src/official_aether_sfm_c.cc',
    ).readAsStringSync();
    final gpu = File(
      '${officialPipeline.path}/src/official_gpu_match.mm',
    ).readAsStringSync();
    final sift = File(
      '${officialPipeline.path}/src/official_dsp_sift_c.cc',
    ).readAsStringSync();

    expect(core, contains('out->match_max_ratio = 0.8f;'));
    expect(
      core,
      contains(
        's->options.match_max_ratio > 0 ? s->options.match_max_ratio : 0.8',
      ),
    );
    expect(gpu, contains('if (maxRatio <= 0.0f) maxRatio = 0.8f;'));
    expect(sift, contains('max_ratio > 0 ? max_ratio : 0.8'));
  });

  test('self-developed phone route remains at ratio 0.7', () {
    final selfRoute = File(
      '${pocketWorld.path}/lib/aether_sfm_ffi.dart',
    ).readAsStringSync();

    expect(selfRoute, contains('..matchMaxRatio = 0.7'));
  });
}
