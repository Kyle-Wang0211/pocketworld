import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/aether_sfm_ffi.dart';

void main() {
  test(
    'publish owner writes the complete native environment every session',
    () {
      final writes = <Map<String, String>>[];

      for (final enabled in <bool>[true, false, true]) {
        final sessionWrites = <String, String>{};
        AetherSfm.configurePublishDepthConflictOwnerForTesting(
          enabled,
          (name, value) => sessionWrites[name] = value,
        );
        writes.add(sessionWrites);
      }

      expect(writes, <Map<String, String>>[
        const <String, String>{
          'AETHER_PUBLISH_GATE': '0',
          'AETHER_PUBLISH_DEPTH_CONFLICT_OWNER': '1',
          'AETHER_PUBLISH_DEPTH_OWNER_ERROR_FIRST': '1',
          'AETHER_EXACT_SITE_OWNER_MIN_DEPTH_M': '0.012',
        },
        const <String, String>{
          'AETHER_PUBLISH_GATE': '1',
          'AETHER_PUBLISH_DEPTH_CONFLICT_OWNER': '0',
          'AETHER_PUBLISH_DEPTH_OWNER_ERROR_FIRST': '0',
          'AETHER_EXACT_SITE_OWNER_MIN_DEPTH_M': '0.012',
        },
        const <String, String>{
          'AETHER_PUBLISH_GATE': '0',
          'AETHER_PUBLISH_DEPTH_CONFLICT_OWNER': '1',
          'AETHER_PUBLISH_DEPTH_OWNER_ERROR_FIRST': '1',
          'AETHER_EXACT_SITE_OWNER_MIN_DEPTH_M': '0.012',
        },
      ]);
    },
  );
}
