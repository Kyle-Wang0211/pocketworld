import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const revision = 'c9ad5779f2803dcc91a9938142209128d30b22d1';

  test('native ABI is a narrow OpenCV 4.0.1 contract', () {
    final header = File(
      'vendor/autocapture_vision/include/pw_autocapture_vision.h',
    ).readAsStringSync();
    final source = File(
      'vendor/autocapture_vision/src/pw_autocapture_vision.cpp',
    ).readAsStringSync();

    for (final symbol in <String>[
      'pw_acv_abi_version',
      'pw_acv_validate_frame',
      'pw_acv_rectify_gray8',
      'pw_acv_clahe_gray8',
      'pw_acv_good_features_to_track',
      'pw_acv_calc_optical_flow_pyr_lk',
      'pw_acv_find_fundamental_mat',
    ]) {
      expect(header, contains(symbol), reason: 'missing $symbol declaration');
      expect(source, contains(symbol), reason: 'missing $symbol definition');
    }

    expect(header, contains('PwAcvFrameView'));
    expect(header, contains('capture_product_id'));
    expect(header, contains('calibration_id'));
    expect(header, contains('timestamp_ns'));
    expect(header, contains('intrinsics_3x3'));
    expect(header, contains('distortion'));
    expect(header, contains('rectification_h_3x3'));
    expect(header, contains('crop_x'));
    expect(header, contains('crop_y'));
    expect(header, contains('crop_width'));
    expect(header, contains('crop_height'));

    expect(source, contains('cv::undistort'));
    expect(source, contains('cv::warpPerspective'));
    expect(source, contains('cv::createCLAHE'));
    expect(source, contains('cv::goodFeaturesToTrack'));
    expect(source, contains('cv::calcOpticalFlowPyrLK'));
    expect(source, contains('cv::findFundamentalMat'));
    expect(source, contains('cv::setRNGSeed'));
    expect(source, contains('std::mutex'));
    expect(source, contains('cv::FM_RANSAC'));

    // Production algorithm constants are fixed in native code, not rewritten
    // in Swift/Kotlin/Dart.
    expect(source, contains('kClaheClipLimit = 3.0'));
    expect(source, contains('kClaheTileGrid = 8'));
    expect(source, contains('kMaximumCorners = 150'));
    expect(source, contains('kCornerQualityLevel = 0.01'));
    expect(source, contains('kCornerBlockSize = 3'));
    expect(source, contains('kLkWindowSize = 21'));
    expect(source, contains('kLkMaximumLevel = 3'));
    expect(source, contains('kLkMaximumIterations = 30'));
    expect(source, contains('kLkEpsilon = 0.01'));
    expect(source, contains('kLkMinimumEigenThreshold = 1e-4'));
  });

  test('receipt freezes dependency, toolchain, ABI, and license identity', () {
    final receiptFile = File(
      'vendor/autocapture_vision/autocapture_vision.receipt.json',
    );
    final receipt = jsonDecode(receiptFile.readAsStringSync())
        as Map<String, dynamic>;

    expect(receipt['schema'], 'pw.autocapture-vision-build-contract/1');
    expect(receipt['opencv_version'], '4.0.1');
    expect(receipt['opencv_revision'], revision);
    expect(receipt['minimum_ios'], '15.0');
    expect(receipt['android_api'], 24);
    expect(receipt['compiler_flags'], contains('-ffp-contract=off'));
    expect(receipt['compiler_flags'], contains('-fno-fast-math'));
    expect(receipt['exported_symbols'], hasLength(7));
    expect(
      receipt['opencv_ios_archive_sha256'],
      '2dac46bd0a07a80fa8f8e6edc736b3fb0b679e91c120b2a1aab789b801dce56d',
    );
    expect(
      receipt['opencv_headers_manifest_sha256'],
      isA<String>().having((value) => value.length, 'length', 64),
    );
    expect(
      File('vendor/autocapture_vision/THIRD_PARTY_NOTICES/OpenCV.txt')
          .readAsStringSync(),
      allOf(contains('OpenCV'), contains('3-clause BSD License')),
    );
  });

  test('both mobile builds compile the same C++ source and pin 4.0.1', () {
    final podspec = File(
      'vendor/autocapture_vision/autocapture_vision.podspec',
    ).readAsStringSync();
    final cmake = File(
      'android_ready/native/autocapture_vision/CMakeLists.txt',
    ).readAsStringSync();
    final podfile = File('ios/Podfile').readAsStringSync();

    expect(podspec, contains('src/pw_autocapture_vision.cpp'));
    expect(podspec, contains('libopencv_generic_4_0_1.a'));
    expect(podspec, contains("s.platform         = :ios, '15.0'"));
    expect(cmake, contains('pw_autocapture_vision.cpp'));
    expect(cmake, contains('OpenCV_VERSION VERSION_EQUAL "4.0.1"'));
    expect(cmake, contains('c9ad5779f2803dcc91a9938142209128d30b22d1'));
    expect(podfile, contains("pod 'autocapture_vision'"));
    expect(podfile, contains("../vendor/autocapture_vision"));
  });
}
