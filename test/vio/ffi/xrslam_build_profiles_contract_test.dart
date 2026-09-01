import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

void main() {
  const upstreamRevision = '4beb1a942f33da9afbfae2d70e2c641cfc2bb675';
  const upstreamTree = '8dc778aa6e748f1b34c9c96ef083311eab580265';

  test(
    'research profiles cannot silently change the selected product core',
    () {
      final contract = _json(
        'vendor/xrslam/profiles/xrslam_build_profiles.contract.json',
      );
      final profiles = contract['profiles']! as Map<String, Object?>;
      final official =
          profiles['official_ios_semantics']! as Map<String, Object?>;
      final hardened =
          profiles['pocketworld_hardened_generic']! as Map<String, Object?>;

      expect(contract['schema'], 'pw.xrslam.research-build-profiles/1');
      expect(contract['upstream_revision'], upstreamRevision);
      expect(contract['upstream_tree'], upstreamTree);
      expect(contract['product_selection_change'], false);
      expect(
        contract['current_product_profile'],
        'pocketworld_hardened_generic',
      );
      expect(official['research_only'], true);
      expect(official['product_selected'], false);
      expect(hardened['product_selected'], true);
    },
  );

  test('official iOS semantics are source-faithful and unpatched', () {
    final contract = _json(
      'vendor/xrslam/profiles/xrslam_build_profiles.contract.json',
    );
    final official =
        (contract['profiles']!
                as Map<String, Object?>)['official_ios_semantics']!
            as Map<String, Object?>;

    expect(official['xrslam_ios'], true);
    expect(official['threading'], true);
    expect(official['algorithm_change'], false);
    expect(official['source_patches'], isEmpty);
    expect(official['release_floating_point_flags'], <String>[
      '-O3',
      '-ffast-math',
    ]);
    expect(
      official['upstream_ios_toolchain_sha256'],
      'ad3531f41be7390cba4e8f93e93d370108cdc45018413e0c27bb8920a4c31aad',
    );
    expect(
      official['target_source_manifest_sha256'],
      'dde850251a1b5ced4dd258f767a78918b51889c3b103b703a44193f15363a2b5',
    );
    expect(official['camera_timestamp_offset_seconds'], 0);
    expect(official['calibration_policy'], 'exact_machine_calibration_only');
  });

  test('hardened generic deviations and patch identities are explicit', () {
    final contract = _json(
      'vendor/xrslam/profiles/xrslam_build_profiles.contract.json',
    );
    final hardened =
        (contract['profiles']!
                as Map<String, Object?>)['pocketworld_hardened_generic']!
            as Map<String, Object?>;
    final patches = hardened['source_patches']! as List<Object?>;

    expect(hardened['xrslam_ios'], false);
    expect(hardened['threading'], false);
    expect(hardened['algorithm_change'], true);
    expect(hardened['release_floating_point_flags'], <String>[
      '-O3',
      '-ffp-contract=off',
      '-fno-fast-math',
    ]);
    expect(hardened['deviations'], contains('generic_mobile_build_route'));
    expect(hardened['deviations'], contains('zero_inlier_mask_contract'));
    expect(hardened['deviations'], contains('explicit_destroy_lifecycle'));

    for (final patch in patches.cast<Map<String, Object?>>()) {
      final file = File(patch['path']! as String);
      expect(file.existsSync(), true, reason: '${patch['path']}');
      expect(
        sha256.convert(file.readAsBytesSync()).toString(),
        patch['sha256'],
        reason: '${patch['path']}',
      );
    }
  });

  test('current Android identity tells the observed debug and strip truth', () {
    final receipt = _json(
      'vendor/xrslam/profiles/'
      'android_pocketworld_hardened_generic.current.receipt.json',
    );
    final artifact = File(receipt['artifact']! as String);
    final zeroPatch = File(
      'vendor/xrslam/patches/xrslam_zero_inlier_mask.patch',
    );

    expect(receipt['upstream_revision'], upstreamRevision);
    expect(receipt['upstream_tree'], upstreamTree);
    expect(receipt['algorithm_change'], true);
    expect(receipt['xrslam_ios'], false);
    expect(receipt['threading'], false);
    expect(receipt['zero_inlier_mask_patch_applied'], true);
    expect(
      receipt['zero_inlier_mask_patch_sha256'],
      sha256.convert(zeroPatch.readAsBytesSync()).toString(),
    );
    expect(receipt['debug_info_present'], true);
    expect(receipt['artifact_strip_status'], 'not_stripped');
    expect(receipt['rebuild_recipe_requests_strip_debug'], true);
    expect(receipt['recipe_strip_claim_matches_observed_artifact'], false);
    expect(
      sha256.convert(artifact.readAsBytesSync()).toString(),
      receipt['artifact_sha256'],
    );
  });

  test('profile builder verifies identities and never installs artifacts', () {
    final script = File(
      'android_ready/native/xrslam/build_research_profiles.sh',
    );
    final source = script.readAsStringSync();

    expect(source, contains('--verify-contract'));
    expect(source, contains('--build-ios-official'));
    expect(source, contains('--probe-android-official-semantics'));
    expect(source, contains('/private/tmp/pw-xrslam-profile-'));
    expect(source, contains('XRSLAM_IOS=ON'));
    expect(source, contains('XRSLAM_ENABLE_THREADING=ON'));
    expect(source, contains('-ffast-math'));
    expect(source, contains('LC_BUILD_VERSION'));
    expect(source, contains('archive_member_manifest_sha256'));
    expect(source, isNot(contains('device install')));
    expect(source, isNot(contains('flutter install')));

    final verify = Process.runSync('sh', <String>[
      script.path,
      '--verify-contract',
    ]);
    expect(verify.exitCode, 0, reason: '${verify.stdout}\n${verify.stderr}');
    expect('${verify.stdout}', contains('XRSLAM_PROFILE_CONTRACT_VERIFIED'));
  });

  test(
    'Android official semantics is named as a port, not an official sample',
    () {
      final contract = _json(
        'vendor/xrslam/profiles/xrslam_build_profiles.contract.json',
      );
      final port =
          (contract['cross_platform_ports']!
                  as Map<String, Object?>)['android_official_ios_semantics']!
              as Map<String, Object?>;
      final patch = File(port['build_route_patch']! as String);

      expect(port['classification'], 'cross_platform_port_candidate');
      expect(port['official_android_sample'], false);
      expect(port['xrslam_ios'], true);
      expect(port['threading'], true);
      expect(port['algorithm_source_patches'], isEmpty);
      expect(
        sha256.convert(patch.readAsBytesSync()).toString(),
        port['build_route_patch_sha256'],
      );
      final source = patch.readAsStringSync();
      expect(source, contains('XRSLAM_ANDROID_OFFICIAL_IOS_SEMANTICS'));
      expect(source, contains('set(XRSLAM_IOS ON)'));
      expect(source, contains('set(XRSLAM_ENABLE_THREADING ON)'));
      expect(source, isNot(contains('ransac.h')));
      expect(source, isNot(contains('XRSLAMManager.cpp')));
    },
  );

  test('blocked probes never masquerade as built artifact receipts', () {
    final evidence = _json(
      'vendor/xrslam/profiles/build_evidence_2026-08-28.json',
    );
    expect(evidence['product_selection_changed'], false);
    final probes = evidence['probes']! as Map<String, Object?>;
    for (final probe in probes.values.cast<Map<String, Object?>>()) {
      expect(probe['status'], 'blocked');
      expect(probe['artifact'], isNull);
      expect(probe['artifact_sha256'], isNull);
      expect(probe['receipt_emitted'], false);
      expect(probe['blocker'], isNotEmpty);
    }
  });
}
