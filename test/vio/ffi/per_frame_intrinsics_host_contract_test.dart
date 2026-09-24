// [pw 2026-09-23] 逐帧内参宿主接线的契约测试(源码级 + 纯 Dart 解析)。
//
// 数值本身(换算与 pwvi_to_euroc.py 逐位一致、K=NULL 与旧推送逐字节相同、
// 72 字节扩展逐字段)由 C++ 单测钉死:
//   vendor/xrslam/transport/tests/transport_core_test.cpp
//   vendor/xrslam/transport/tests/fork_contract_test.cpp
// 这里钉的是「宿主有没有走那条路」:Swift 不自己写换算算术、两条原生通路
// 都在同一个开关下分叉、旧入口仍在、出货默认链接不变、新符号三套配置都导出。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_live_ffi.dart';

String _read(String path) => File(path).readAsStringSync();

String _body(String source, RegExp pattern) {
  final RegExpMatch? m = pattern.firstMatch(source);
  expect(m, isNotNull, reason: 'pattern not found: ${pattern.pattern}');
  return m!.group(0)!;
}

void main() {
  test('mirror header carries the fork 04c0e83 per-frame intrinsics layout', () {
    final String header = _read('vendor/xrslam/include/XRSLAM.h');
    expect(header, contains('unsigned int ext_size;'));
    expect(header, contains('double intrinsics_fxfycxcy[4];'));
    expect(header, contains('int has_intrinsics;'));
    expect(header, contains('XRSLAM_IMAGE_EXTENSION_LEGACY_SIZE 32u'));
    expect(header, contains('04c0e83e9c4889612880529dd49dd8063819a776'));
    // ext_size sits between channel and ext (the upstream padding).
    final int channel = header.indexOf('int channel;');
    final int extSize = header.indexOf('unsigned int ext_size;');
    final int ext = header.indexOf('XRSLAMImageExtension *ext;');
    expect(channel, lessThan(extSize));
    expect(extSize, lessThan(ext));
  });

  test('transport keeps the legacy push as a NULL-K wrapper of the new one', () {
    final String h = _read('vendor/xrslam/transport/PwXrslamTransportCore.h');
    final String cpp =
        _read('vendor/xrslam/transport/PwXrslamTransportCore.cpp');
    expect(h, contains('int32_t PWXrslamTransportPushCameraAndRunRaw('));
    expect(h, contains('PWXrslamTransportPushCameraAndRunRawWithIntrinsics('));
    expect(h, contains('PWXrslamTransportScaleIntrinsicsForBoxNxN('));
    expect(h, contains('PWXrslamTransportGetIntrinsicsTrace('));
    final String legacy = _body(
      cpp,
      RegExp(
        r'extern "C" int32_t PWXrslamTransportPushCameraAndRunRaw\([\s\S]*?\n\}',
      ),
    );
    expect(legacy, contains('PWXrslamTransportPushCameraAndRunRawWithIntrinsics('));
    expect(legacy, contains('nullptr'));
    // Still exactly one camera push into the core.
    expect(
      RegExp(r'XRSLAMPushSensorData\(XRSLAM_SENSOR_CAMERA').allMatches(cpp),
      hasLength(1),
    );
    // The rescale is the converter's expression, verbatim operations.
    expect(cpp, contains('destination[0] = source[0] / d;'));
    expect(cpp, contains('destination[2] = (source[2] + 0.5) / d - 0.5;'));
    expect(cpp, contains('destination[3] = (source[3] + 0.5) / d - 0.5;'));
    expect(cpp, contains('pwvi_to_euroc.py:224-226'));
    expect(cpp, contains('static_assert(sizeof(XRSLAMImageExtension) == 72'));
  });

  test('ARKit shadow path rescales only through the transport function', () {
    final String feeder = _read('ios/Runner/PwVioSlamFeeder.swift');
    final String consume = _body(
      feeder,
      RegExp(
        r'public func consume\(permit: FrameIngressPermit\) -> Bool \{[\s\S]*?\n  \}',
      ),
    );
    expect(consume, contains('PWXrslamTransportScaleIntrinsicsForBoxNxN('));
    expect(consume, contains('Int32(factor)'));
    // K is only valid for the plane it refers to (ARCamera.imageResolution).
    expect(consume, contains('permit.cameraImageResolution.width != CGFloat(sourceWidth)'));
    expect(consume, contains('permit.cameraImageResolution.height != CGFloat(sourceHeight)'));
    expect(
      consume.indexOf('PWXrslamTransportPrepareGrayBoxNxN('),
      lessThan(consume.indexOf('PWXrslamTransportScaleIntrinsicsForBoxNxN(')),
    );
    // No hand-written rescale arithmetic in Swift.
    for (final String arithmetic in <String>[
      '+ 0.5',
      '- 0.5',
      '/ Double(factor)',
      '/ 3.0',
    ]) {
      expect(feeder, isNot(contains(arithmetic)), reason: arithmetic);
    }
    final String offer = _body(
      feeder,
      RegExp(
        r'public func tryOfferFrame\(frame: ARFrame\) -> FrameIngressPermit\? \{[\s\S]*?\n  \}',
      ),
    );
    expect(offer, contains('let cameraIntrinsics = frame.camera.intrinsics'));
    expect(
      offer,
      contains('let cameraImageResolution = frame.camera.imageResolution'),
    );
    final String core = _body(
      feeder,
      RegExp(r'private func processFrameOnCore\([\s\S]*?\n  \}'),
    );
    final int submit = core.indexOf('imageFacts.submit()');
    expect(core.indexOf('PWXrslamTransportPushCameraAndRunRawWithIntrinsics('),
        allOf(greaterThanOrEqualTo(0), lessThan(submit)));
    expect(core.indexOf('PWXrslamTransportPushCameraAndRunRaw('),
        allOf(greaterThanOrEqualTo(0), lessThan(submit)));
    expect(core, contains('PWXrslamTransportGetIntrinsicsTrace('));
    expect(feeder, contains('"perFrameIntrinsics": perFrameIntrinsicsWireLocked()'));
    expect(feeder, contains('observation["intrinsicsSource"]'));
  });

  test('zero-ARKit ON arm pushes the attachment K raw, per frame', () {
    final String live = _read('ios/Runner/PwXrslamLive.swift');
    final String slot = _read('ios/Runner/PwCameraSlot.swift');
    expect(live, contains('static let kLaunchArgumentKey = "PWPerFrameIntrinsics"'));
    // Default on when the launch argument is absent.
    expect(
      live,
      contains(
        'if v.isEmpty { return Resolved(enabled: true, source: .defaultValue, raw: raw) }',
      ),
    );
    expect(live, contains('frameK = [k.fx, k.fy, k.cx, k.cy]'));
    expect(live, contains('k.referenceWidth != pushedWidth'));
    expect(live, contains('k.activeFormatWidth != pushedWidth'));
    expect(live, contains('PWXrslamTransportPushCameraAndRunRawWithIntrinsics('));
    expect(live, contains('PWXrslamTransportPushCameraAndRunRaw('));
    expect(live, contains('@_cdecl("pw_xrslam_live_intrinsics")'));
    // The K travels with its own frame into the worker.
    expect(live, contains('intrinsics: intrinsics)'));
    expect(slot, contains('intrinsics: frameIntrinsics)'));
    expect(slot, contains('raw.count >= MemoryLayout<matrix_float3x3>.size'));
    expect(slot, contains('loadUnaligned(as: matrix_float3x3.self)'));
    expect(slot, contains('CMSampleBufferGetFormatDescription(sampleBuffer)'));
  });

  test('new C ABI symbol is kept and exported in every Runner configuration', () {
    final String pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
    expect(
      RegExp(r'"-Wl,-u,_pw_xrslam_live_intrinsics"').allMatches(pbx),
      hasLength(3),
    );
    expect(
      RegExp(r'"-Wl,-exported_symbol,_pw_xrslam_live_intrinsics"')
          .allMatches(pbx),
      hasLength(3),
    );
  });

  test('engine arm switch: default stays generic, new arm is receipt-bound', () {
    final String podfile = _read('ios/Podfile');
    expect(podfile, contains("xrslam_engine = 'generic' if xrslam_engine.empty?"));
    expect(podfile, contains("'libxrslam_generic_4beb1a9.a', 'fdc75c99358014d9'"));
    expect(
      podfile,
      contains("'libxrslam_gpufenothread_pfk_6f6aa21c.a', '6f6aa21cad6e534c'"),
    );
    final String stamp = _read('ios/scripts/stamp_runtime_identity.sh');
    expect(stamp, contains('gpufenothread_pfk)'));
    expect(stamp, contains('xrslam_other_fingerprint_2'));

    const String dir = 'vendor/xrslam/libs/ios-arm64';
    final Map<String, Object?> receipt = jsonDecode(
      _read('$dir/libxrslam_gpufenothread_pfk_6f6aa21c.receipt.json'),
    ) as Map<String, Object?>;
    final String sha = sha256
        .convert(File('$dir/libxrslam_gpufenothread_pfk_6f6aa21c.a').readAsBytesSync())
        .toString();
    expect(receipt['artifact_sha256'], sha);
    expect(sha.substring(0, 16), '6f6aa21cad6e534c');
    expect(receipt['research_only'], isTrue);
    expect(receipt['product_selected'], isFalse);
    final Map<String, Object?> source =
        receipt['source']! as Map<String, Object?>;
    expect(source['commit'], '04c0e83e9c4889612880529dd49dd8063819a776');
    expect(source['tracked_dirty_files'], 0);
    // The shipping archive is untouched.
    expect(
      sha256.convert(File('$dir/libxrslam_generic_4beb1a9.a').readAsBytesSync()).toString(),
      'fdc75c99358014d9485bea36667547825465a85562847548d02a582da38c8011',
    );
  });

  test('XrslamLiveIntrinsics parses the 31-double native report', () {
    final List<double> wire = <double>[
      1, 0, 120, // switch on, default, frames
      118, 2, 0, // attached, not attached, rejected
      0, 118, // report differs, report equal (not evidence)
      -1, // no build identity stamp
      0, 2, 0, 0, 0, 0, // host reasons
      4, // last source: per_frame_attached_unverified
      1286.1873779296875, 1286.1873779296875, 957.7037963867188, 719.0327758789062,
      1286.1873779296875, 1286.1873779296875, 957.7037963867188, 719.0327758789062,
      1280.49, 1347.79, 1920, 1440, 1920, 1440, 0,
    ];
    final XrslamLiveIntrinsics? r = XrslamLiveIntrinsics.fromWire(wire);
    expect(r, isNotNull);
    expect(r!.switchEnabled, isTrue);
    expect(r.switchParseFailed, isFalse);
    expect(r.armLabel, 'per_frame_k_on');
    expect(r.attached, 118);
    expect(r.engineReportEqualNotEvidence, 118);
    expect(r.engineReportDiffers, 0);
    expect(r.notAttached, 2);
    expect(r.hostNoAttachment, 2);
    // Equal read-back without a build identity is NOT reported as consumed.
    expect(r.lastSourceLabel, 'per_frame_attached_unverified');
    expect(r.engineConsumesLabel, 'unverifiable_no_build_identity');
    expect(r.pushedWidth, 1920);
    expect(r.configWidth, 1920);
    expect(r.configHeight, 1440);
    final Map<String, Object?> json = r.toJson();
    expect(json['arm'], 'per_frame_k_on');
    expect(json['switch_launch_argument'], '-PWPerFrameIntrinsics');
    expect(json['last_attached_fxfycxcy'], hasLength(4));
    expect(json.keys.where((String k) => k.contains('matched')), isEmpty);
    expect(json['transport_engine_report_equal_not_evidence'], 118);
    expect(XrslamLiveIntrinsics.fromWire(wire.sublist(0, 30)), isNull);
    final List<double> off = List<double>.of(wire)..[0] = 0;
    expect(XrslamLiveIntrinsics.fromWire(off)!.armLabel, 'per_frame_k_off');
    // Unparseable launch argument: still on, but the failure is in the record.
    final List<double> bad = List<double>.of(wire)..[1] = 2;
    final XrslamLiveIntrinsics b = XrslamLiveIntrinsics.fromWire(bad)!;
    expect(b.armLabel, 'per_frame_k_on');
    expect(b.toJson()['switch_parse_failed'], isTrue);
    expect(b.toJson()['switch_source'], 'unparseable_fell_back_to_default_on');
    // Build identity says the linked core is the per-frame-K arm.
    final List<double> pfk = List<double>.of(wire)
      ..[8] = 1
      ..[15] = 2;
    final XrslamLiveIntrinsics p = XrslamLiveIntrinsics.fromWire(pfk)!;
    expect(p.lastSourceLabel, 'per_frame');
    expect(p.engineConsumesLabel, 'build_identity_per_frame_k_arm');
  });

  test('consumption is never inferred from an equal engine read-back', () {
    final String h = _read('vendor/xrslam/transport/PwXrslamTransportCore.h');
    final String cpp =
        _read('vendor/xrslam/transport/PwXrslamTransportCore.cpp');
    final String live = _read('ios/Runner/PwXrslamLive.swift');
    final String feeder = _read('ios/Runner/PwVioSlamFeeder.swift');
    for (final String src in <String>[h, cpp, live, feeder]) {
      expect(src, isNot(contains('engine_report_matched')));
      expect(src, isNot(contains('last_engine_report_matches')));
    }
    expect(h, contains('uint64_t engine_report_differs;'));
    expect(h, contains('uint64_t engine_report_equal;'));
    expect(cpp, contains('++trace.engine_report_equal;'));
    // The one place that turns facts into a label.
    final String classify = _body(
      live,
      RegExp(r'static func classify\([\s\S]*?\n    \}'),
    );
    expect(classify, contains('if engineReportDiffers { return .perFrameNotConsumed }'));
    expect(classify, contains('PwXrslamEngineIdentity.consumesPerFrameK'));
    expect(classify, contains('default: return .perFrameAttachedUnverified'));
    expect(live, contains('PwPerFrameIntrinsicsSource.classify('));
    expect(feeder, contains('PwPerFrameIntrinsicsSource.classify('));
    // Build identity = the Info.plist key the Release stamp writes after its
    // fingerprint check.
    expect(live, contains('static let kInfoPlistKey = "PWXrslamEngineArm"'));
    expect(live, contains('static let kPerFrameKArm = "gpufenothread_pfk"'));
    final String stamp = _read('ios/scripts/stamp_runtime_identity.sh');
    expect(stamp, contains(r'set_plist_string "PWXrslamEngineArm" "$pw_xrslam_engine_linked"'));
    expect(stamp, contains('gpufenothread_pfk)'));
  });

  test('ON arm attaches K only when the pushed size equals the yaml cam0.resolution', () {
    final String live = _read('ios/Runner/PwXrslamLive.swift');
    expect(live, contains('PwXrslamDeviceYaml.cam0Resolution(atPath: deviceConfigPath)'));
    expect(live, contains('cfg.width != pushedWidth || cfg.height != pushedHeight'));
    expect(live, contains('hostReason = 5'));
    expect(live, contains('hostReason = 6'));
    // The Swift reader expects exactly what the Dart builder writes: a
    // top-level `cam0:` block with a two-space-indented `resolution: [ W, H ]`.
    expect(live, contains('line.hasPrefix("  resolution:")'));
    expect(live, contains('== "cam0:"'));
    const CameraIntrinsics k = CameraIntrinsics(
      fx: 1347.79,
      fy: 1347.79,
      cx: 957.47,
      cy: 718.96,
      resolutionWidth: 1920,
      resolutionHeight: 1440,
      provenance: FieldProvenance.deviceApi,
    );
    final List<String> lines =
        const XrslamConfigBuilder(intrinsics: k).buildDeviceConfigYaml().split('\n');
    final int cam0 = lines.indexOf('cam0:');
    expect(cam0, greaterThanOrEqualTo(0));
    final List<String> hits = <String>[
      for (final String l in lines)
        if (l.startsWith('  resolution:')) l,
    ];
    expect(hits, <String>['  resolution: [ 1920, 1440 ]']);
    final int at = lines.indexOf('  resolution: [ 1920, 1440 ]');
    expect(at, greaterThan(cam0));
    // No other top-level key between `cam0:` and the resolution line.
    for (int i = cam0 + 1; i < at; i++) {
      final String l = lines[i];
      expect(l.isEmpty || l.startsWith(' ') || l.startsWith('#'), isTrue,
          reason: 'line $i "$l" leaves the cam0 block');
    }
  });

  test('unparseable -PWPerFrameIntrinsics is recorded in diagnostics, not only NSLog', () {
    final String live = _read('ios/Runner/PwXrslamLive.swift');
    final String feeder = _read('ios/Runner/PwVioSlamFeeder.swift');
    expect(live, contains('return Resolved(enabled: true, source: .unparseable, raw: raw)'));
    expect(live, contains('out[1] = Double(sw.source.rawValue)'));
    expect(feeder, contains('"switchParseFailed": PwPerFrameIntrinsicsSwitch.parseFailed'));
    expect(feeder, contains('"switchRaw": sw.raw'));
  });
}
