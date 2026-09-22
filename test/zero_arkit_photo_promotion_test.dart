// zero_arkit_photo_promotion_test.dart —— 零 ARKit 臂(开关 ON)按下快门后,
// 成片真的能被 `CaptureSession` 提升(promote)入库。
//
// 静态排查出的三处断点(integration@3e50521)与本文件各组的对应:
//   ① 逐帧持久化闸要 `scaleAlignAnchorCount >= 8`,VIO 如实报 0 ⇒ 每帧 skip
//      → (A) 闸函数逐源:arkit 仍要锚点、xrslam 不要、未知源抛。
//   ② `captureHighResolutionStill` 拍了一张返回 null;`saveCurrentFrame` 又拍一张
//      并报 `saved_elsewhere` ⇒ 一张进不了库、一次快门两次曝光
//      → (C) saveCurrentFrame 落到 spec 两个路径 + sidecar 逐键;
//        (D) captureHighResolutionStill 返回 null 且 **0 次** capturePhoto。
//   ③ sidecar 完整性闸要 `anchors_world` 非空 + `anchor_depth_count >= 8`
//      → (B) ARKit 夹具 anchors=0 仍被拒(不变)、VIO 夹具被接受、缺
//        `poseSource` 键按 ARKit。
//   ④(排查时没列、写代码时发现)生产采集页只以 `manualCapture: true` 起会话
//      (`ar_capture_page.dart` `_startManualCapture` 两个入口都是),快门走
//      `captureSinglePhoto` → `_captureOfficialHighResInput`,那条路上 null still
//      是终态 `captureFailed`,**没有** fallback
//      → (G) 端到端:VioArPoseProvider + CaptureSession 手动快门 ⇒ 入库;
//        ARKit 标签的 null still 仍抛(阴性对照);1920×1440 被 4032×3024 硬闸拒。
//
// 🔴 全程不等真实定时器(pollInterval 1h,手工 tick),不开相机、不碰真机。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';
import 'package:pocketworld_flutter/official_capture/capture_archive_service.dart';
import 'package:pocketworld_flutter/official_capture/capture_session.dart';
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:pocketworld_flutter/vio/capture/zero_arkit_photo_api.dart';
import 'package:pocketworld_flutter/vio/capture/zero_arkit_scale_provenance.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_bindings.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/engine_pose_poller.dart';
import 'package:pocketworld_flutter/vio/pose/vio_ar_pose_provider.dart';
import 'package:vector_math/vector_math_64.dart';

/// `CaptureSession.attach()` 会起 `OrientationTracker`(sensors_plus)。
/// 单测里那个插件不存在 ⇒ 桩掉它,与 `zero_arkit_capture_path_test.dart` 同款。
const MethodChannel _sensorsMethodChannel =
    MethodChannel('dev.fluttercommunity.plus/sensors/method');

/// 与 `test/zero_arkit_capture_path_test.dart` 的 `_FakePhotoApi` 同款替身,
/// 区别只有一点:**JPEG 路径指向临时目录里一个真文件**(拍照时当场写出),
/// 好让 `saveCurrentFrame` 的搬文件那一步是真的。
class _FilePhotoApi implements ZeroArkitPhotoApi {
  _FilePhotoApi(
    this.dir, {
    this.extension = 'jpg',
    this.width = 4032,
    this.height = 3024,
    this.writeNativeSidecar = false,
  });

  final Directory dir;
  final String extension;
  final int width;
  final int height;
  final bool writeNativeSidecar;
  final List<int> requests = <int>[];
  final List<String> writtenPaths = <String>[];
  ZeroArkitPhotoResult? pending;

  /// 每张照片的字节都不同,好核对"搬过去的是这一张"。
  static List<int> bytesFor(int requestId) =>
      <int>[0xFF, 0xD8, 0xFF, requestId & 0xFF, 0xFF, 0xD9];

  @override
  int? capturePhoto(int requestId) {
    requests.add(requestId);
    final String path = '${dir.path}/pw_photos/$requestId.$extension';
    File(path).createSync(recursive: true);
    File(path).writeAsBytesSync(bytesFor(requestId));
    writtenPaths.add(path);
    if (writeNativeSidecar) {
      // 抄 `PwCameraSlot.swift` 的 sidecar 里两条 provenance 键。
      File('${dir.path}/pw_photos/$requestId.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'source': 'avfoundation_photo_output',
          'intrinsics_provenance': 'photo_camera_calibration_data',
          'exposure_provenance': 'photo_exif_exposure_time',
        }),
      );
    }
    pending = ZeroArkitPhotoResult(
      requestId: requestId,
      path: path,
      fx: 2800,
      fy: 2800,
      cx: 2016,
      cy: 1512,
      width: width,
      height: height,
      timestampSeconds: 12.5,
      exposureSeconds: 0.00833,
    );
    return requestId;
  }

  @override
  ZeroArkitPhotoResult? photoResult() => pending;
}

/// 引擎报 TRACKING_SUCCESS 的固定位姿 ⇒ tick 一次就是 6DOF、extrinsic 16 个。
final Quaternion _qEngine = Quaternion.axisAngle(
  Vector3(0.2, 0.9, 0.1).normalized(),
  0.7,
);
const List<double> _pEngine = <double>[0.31, -0.12, 1.05];

VioArPoseProvider _trackingProvider(ZeroArkitPhotoApi photoApi) =>
    VioArPoseProvider(
      photoApi: photoApi,
      pollInterval: const Duration(hours: 1),
      poller: EnginePosePoller(
        readEngine: () => EngineSnapshot(
          state: XRSLAMState.XRSLAM_STATE_TRACKING_SUCCESS.value,
          quaternionXyzw: <double>[
            _qEngine.x,
            _qEngine.y,
            _qEngine.z,
            _qEngine.w,
          ],
          translationXyz: _pEngine,
          timestampSeconds: 12.4,
        ),
      ),
      intrinsicsReader: () => const PinholeIntrinsics(
        fx: 1359.37,
        fy: 1359.37,
        cx: 960.0,
        cy: 720.0,
        imageWidth: 1920,
        imageHeight: 1440,
      ),
    );

/// 原生 ARKit 帧 sidecar 的形状(`OfficialAetherARKitPlugin.swift:2763-2790`),
/// 没有 `poseSource` 键。
Map<String, Object?> _arkitSidecar({required int anchors}) => <String, Object?>{
  'version': 1,
  'native_role': 'thin_arkit_frame_executor',
  't': 100.5,
  'image_w': 4032,
  'image_h': 3024,
  'extrinsic': List<double>.generate(16, (i) => i % 5 == 0 ? 1.0 : 0.0),
  'intrinsics_fxfycxcy': <double>[2800, 2800, 2016, 1512],
  'trackingStateName': 'normal',
  'tracking_state': 'normal',
  'is_tracking': true,
  'anchors_world': List<List<double>>.generate(
    anchors,
    (i) => <double>[i * 0.1, 0.2, 1.0],
  ),
  'anchor_ids': List<int>.generate(anchors, (i) => i),
  'scale_align_premetrics': <String, Object?>{
    'anchor_depth_count': anchors,
    'anchor_depth_min_m': anchors == 0 ? 0.0 : 0.8,
    'anchor_depth_max_m': anchors == 0 ? 0.0 : 1.4,
    'anchor_depth_span_m': anchors == 0 ? 0.0 : 0.6,
    'reliability_prior': anchors == 0 ? 0.0 : 0.9,
  },
  'save_dt': 0.0,
};

/// ARKit 标签(不实现 `ARPoseSourceLabel`)、高清 still 返回 null 的 provider。
/// 阴性对照用:证明 ARKit 路径上 null still 仍是终态失败,**不去**走 fallback。
class _ArkitNullStillProvider implements ARPoseProvider {
  final StreamController<ARPose> _poses = StreamController<ARPose>.broadcast(
    sync: true,
  );
  ARPose? _lastPose;
  int highResCalls = 0;
  final List<ARFrameSaveSpec> saveSpecs = <ARFrameSaveSpec>[];

  @override
  ARPose? get lastPose => _lastPose;

  void emitPose() {
    _lastPose = ARPose(
      position: Vector3(0, 0, 1),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      timestamp: 10,
      hasOrigin: true,
      worldOrigin: Vector3.zero(),
      worldYaw: 0,
      extrinsic4x4: List<double>.generate(16, (i) => i % 5 == 0 ? 1.0 : 0.0),
      intrinsicFxFyCxCy: const <double>[2000, 2000, 2016, 1512],
      trackingStateName: 'normal',
    );
    _poses.add(_lastPose!);
  }

  @override
  Stream<ARPose> start() => _poses.stream;

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async => null;

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false;

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async {
    saveSpecs.add(spec);
    // 若 fallback 被错误地打开,这份"完整的 ARKit sidecar"会让它过闸 ——
    // 所以下面用例断言的是"根本没为证据 spec 调过这里"。
    await File(spec.jpegPath).parent.create(recursive: true);
    await File(spec.jpegPath).writeAsBytes(<int>[1, 2, 3]);
    await File(spec.metadataPath).parent.create(recursive: true);
    await File(
      spec.metadataPath,
    ).writeAsString(jsonEncode(_arkitSidecar(anchors: 12)));
    return ARFrameSaveResult(spec: spec, status: 'saved');
  }

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
    bool feedSfm = false,
    bool deriveAuxiliary = true,
    bool stagePhotoFeedback = false,
    String? transactionId,
    String? cardTexturePath,
    double? maxTimestampDelta,
  }) async {
    highResCalls++;
    return null;
  }

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_sensorsMethodChannel, (_) async => null);
    tmp = await Directory.systemTemp.createTemp('zero-arkit-promotion-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_sensorsMethodChannel, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ══ (A) 闸函数逐源 ═══════════════════════════════════════════════════════
  group('(A) 位姿源感知的闸:显式穷举 switch', () {
    test('锚点要求:arkit 要(不变)、xrslam 不要、imu 不要、未知源抛', () {
      expect(
        CaptureSession.debugPoseSourceRequiresScaleAlignAnchors('arkit'),
        isTrue,
      );
      expect(
        CaptureSession.debugPoseSourceRequiresScaleAlignAnchors('xrslam'),
        isFalse,
        reason: '出货引擎 RESULT_FEATURES 是空实现,VIO 如实报 0 锚点;'
            '要求 >= 8 就等于永远拒',
      );
      expect(
        CaptureSession.debugPoseSourceRequiresScaleAlignAnchors('imu'),
        isFalse,
      );
      expect(
        () => CaptureSession.debugPoseSourceRequiresScaleAlignAnchors('who'),
        throwsA(isA<StateError>()),
      );
    });

    test('手动路径 sidecar 提升:arkit 否(不变)、xrslam 是、imu 否、未知源抛', () {
      expect(
        CaptureSession.debugPoseSourcePromotesStillViaFrameSidecar('arkit'),
        isFalse,
      );
      expect(
        CaptureSession.debugPoseSourcePromotesStillViaFrameSidecar('xrslam'),
        isTrue,
      );
      expect(
        CaptureSession.debugPoseSourcePromotesStillViaFrameSidecar('imu'),
        isFalse,
      );
      expect(
        () => CaptureSession.debugPoseSourcePromotesStillViaFrameSidecar('who'),
        throwsA(isA<StateError>()),
      );
    });

    test('fallback still 的 captureKind:ARKit 字符串一个字符不改,xrslam 另起', () {
      final arkit = CaptureSession.debugFallbackStillKindForPoseSource('arkit');
      expect(arkit.captureKind, 'arkit_frame_fallback_jpeg');
      expect(arkit.poseSyncQuality, 'nearest_ar_frame_snapshot');
      final vio = CaptureSession.debugFallbackStillKindForPoseSource('xrslam');
      expect(vio.captureKind, 'xrslam_frame_fallback_jpeg');
      expect(vio.captureKind, isNot(startsWith('arkit')));
      expect(vio.poseSyncQuality, isNot(arkit.poseSyncQuality));
      expect(
        () => CaptureSession.debugFallbackStillKindForPoseSource('imu'),
        throwsA(isA<StateError>()),
        reason: 'IMU 帧从不落盘,声称 imu 的 sidecar 不是本会话写的',
      );
      expect(
        () => CaptureSession.debugFallbackStillKindForPoseSource('who'),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ══ (B) sidecar 完整性闸 ═════════════════════════════════════════════════
  group('(B) _isCompleteArFrameSidecar 位姿源感知', () {
    test('ARKit 夹具 anchors=0 仍被拒(不变)', () {
      expect(
        CaptureSession.debugIsCompleteArFrameSidecar(
          _arkitSidecar(anchors: 0),
        ),
        isFalse,
      );
    });

    test('ARKit 夹具 anchors=8 仍被接受(不变)', () {
      expect(
        CaptureSession.debugIsCompleteArFrameSidecar(
          _arkitSidecar(anchors: 8),
        ),
        isTrue,
      );
    });

    test('VIO 夹具(poseSource=xrslam、anchors 空、count=0)被接受', () {
      final vio = _arkitSidecar(anchors: 0)..['poseSource'] = 'xrslam';
      expect(CaptureSession.debugIsCompleteArFrameSidecar(vio), isTrue);
    });

    test('🔴 VIO 夹具缺 poseSource 键 ⇒ 按 ARKit 处理 ⇒ 被拒(旧 sidecar 语义不变)',
        () {
      final noKey = _arkitSidecar(anchors: 0);
      expect(noKey.containsKey('poseSource'), isFalse);
      expect(CaptureSession.debugIsCompleteArFrameSidecar(noKey), isFalse);
    });

    test('VIO 夹具其余项仍要齐:不在跟踪 / extrinsic 不够 16 / 无内参 ⇒ 拒', () {
      final base = _arkitSidecar(anchors: 0)..['poseSource'] = 'xrslam';
      expect(
        CaptureSession.debugIsCompleteArFrameSidecar(
          Map<String, Object?>.of(base)..['is_tracking'] = false,
        ),
        isFalse,
      );
      expect(
        CaptureSession.debugIsCompleteArFrameSidecar(
          Map<String, Object?>.of(base)..['trackingStateName'] = 'limited',
        ),
        isFalse,
      );
      expect(
        CaptureSession.debugIsCompleteArFrameSidecar(
          Map<String, Object?>.of(base)..['extrinsic'] = <double>[1, 0, 0],
        ),
        isFalse,
      );
      expect(
        CaptureSession.debugIsCompleteArFrameSidecar(
          Map<String, Object?>.of(base)..['intrinsics_fxfycxcy'] = <double>[],
        ),
        isFalse,
      );
    });

    test('未知 poseSource 抛 StateError,不静默当 ARKit', () {
      final bogus = _arkitSidecar(anchors: 8)..['poseSource'] = 'who_knows';
      expect(
        () => CaptureSession.debugIsCompleteArFrameSidecar(bogus),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ══ (C) saveCurrentFrame 真正落到 spec ══════════════════════════════════
  group('(C) VioArPoseProvider.saveCurrentFrame', () {
    /// 原生契约的键(`OfficialAetherARKitPlugin.swift:2763-2790`)。
    const List<String> nativeContractKeys = <String>[
      'version',
      'native_role',
      't',
      'image_w',
      'image_h',
      'extrinsic',
      'intrinsics_fxfycxcy',
      'trackingStateName',
      'tracking_state',
      'is_tracking',
      'anchors_world',
      'anchor_ids',
      'scale_align_premetrics',
      'save_dt',
      'dart_save_contract',
      'save_target_t',
    ];
    const List<String> premetricsKeys = <String>[
      'anchor_depth_count',
      'anchor_depth_min_m',
      'anchor_depth_max_m',
      'anchor_depth_span_m',
      'reliability_prior',
    ];

    test('🔴 一次调用只拍一张;JPEG 到 spec.jpegPath、sidecar 到 spec.metadataPath;返回 saved',
        () async {
      final photo = _FilePhotoApi(tmp, writeNativeSidecar: true);
      final provider = _trackingProvider(photo);
      provider.tick();
      final ARPose pose = provider.lastPose!;
      expect(pose.isTracking, isTrue);
      expect(pose.extrinsic4x4, hasLength(16));

      final spec = ARFrameSaveSpec(
        frameID: 'tap-1',
        cellIndex: -1,
        slotIndex: -1,
        jpegPath: '${tmp.path}/capture/photos/official_tap-1.jpg',
        metadataPath: '${tmp.path}/capture/photos/official_tap-1.json',
        targetTimestamp: pose.timestamp,
        quality: 0.92,
        includeSfmFeed: false,
      );
      final res = await provider.saveCurrentFrame(spec);

      expect(res.status, 'saved', reason: res.message);
      expect(res.saved, isTrue);
      expect(photo.requests, hasLength(1), reason: '一次快门一次曝光');

      // JPEG 搬过去了:目标存在、字节就是这一张、源已不在。
      final int id = photo.requests.single;
      expect(File(spec.jpegPath).existsSync(), isTrue);
      expect(File(spec.jpegPath).readAsBytesSync(), _FilePhotoApi.bytesFor(id));
      expect(File(photo.writtenPaths.single).existsSync(), isFalse);
      // 原生孤儿 sidecar 也收掉了(内容嵌进我们的 sidecar)。
      expect(File('${tmp.path}/pw_photos/$id.json').existsSync(), isFalse);

      // sidecar 逐键。
      final decoded =
          jsonDecode(File(spec.metadataPath).readAsStringSync())
              as Map<String, Object?>;
      for (final k in nativeContractKeys) {
        expect(decoded.containsKey(k), isTrue, reason: '缺原生契约键 $k');
      }
      final premetrics = decoded['scale_align_premetrics'] as Map;
      for (final k in premetricsKeys) {
        expect(premetrics.containsKey(k), isTrue, reason: '缺 premetrics 键 $k');
      }
      expect(decoded['version'], spec.metadataSchemaVersion);
      expect(decoded['t'], 12.5);
      expect(decoded['image_w'], 4032);
      expect(decoded['image_h'], 3024);
      expect(decoded['intrinsics_fxfycxcy'], <double>[2800, 2800, 2016, 1512]);
      expect(decoded['trackingStateName'], 'normal');
      expect(decoded['tracking_state'], 'normal');
      expect(decoded['is_tracking'], isTrue);
      expect(decoded['anchors_world'], isEmpty);
      expect(decoded['anchor_ids'], isEmpty);
      expect(premetrics['anchor_depth_count'], 0);
      expect(decoded['save_target_t'], pose.timestamp);
      expect(decoded['save_dt'], closeTo((12.5 - pose.timestamp).abs(), 1e-12));
      expect(
        (decoded['dart_save_contract'] as Map)['frame_id'],
        'tap-1',
      );
      // extrinsic 16 个数 == 当时 ARPose 的。
      final ext = (decoded['extrinsic'] as List).cast<num>();
      expect(ext, hasLength(16));
      for (var i = 0; i < 16; i++) {
        expect(ext[i].toDouble(), closeTo(pose.extrinsic4x4[i], 1e-12));
      }
      // 额外键(只加不改)。
      expect(decoded['poseSource'], 'xrslam');
      expect(decoded['source'], 'avfoundation_photo_output');
      expect(decoded['exposure_s'], closeTo(0.00833, 1e-12));
      expect(decoded['photo_request_id'], id);
      final scale = decoded['scale_provenance'] as Map;
      expect(scale['scale'], kScaleProvenanceVioUnanchored);
      expect(scale['may_report_absolute_dimensions'], isFalse);
      final pairing = decoded['pose_pairing'] as Map;
      expect(pairing['policy'], 'vio_pose_at_trigger');
      expect(pairing['pose_t'], pose.timestamp);
      expect(pairing['photo_t'], 12.5);
      final native = decoded['native_photo_sidecar'] as Map;
      expect(native['intrinsics_provenance'], 'photo_camera_calibration_data');

      // 闭环:CaptureSession 的 sidecar 闸对这份文件放行。
      expect(CaptureSession.debugIsCompleteArFrameSidecar(decoded), isTrue);

      await provider.dispose();
    });

    test('🔴 位姿不在跟踪时照拍照写,但 extrinsic 空、is_tracking=false ⇒ 闸拒(不编)',
        () async {
      final photo = _FilePhotoApi(tmp);
      // 无引擎数据:tick 之后有位姿但不是 6DOF。
      final provider = VioArPoseProvider(
        photoApi: photo,
        pollInterval: const Duration(hours: 1),
      );
      provider.tick();
      expect(provider.lastPose!.isTracking, isFalse);
      final spec = ARFrameSaveSpec(
        frameID: 'tap-2',
        cellIndex: -1,
        slotIndex: -1,
        jpegPath: '${tmp.path}/capture/photos/official_tap-2.jpg',
        metadataPath: '${tmp.path}/capture/photos/official_tap-2.json',
        targetTimestamp: 1.0,
      );
      final res = await provider.saveCurrentFrame(spec);
      expect(res.saved, isTrue, reason: '两个文件都落了,saved 是文件事实');
      final decoded =
          jsonDecode(File(spec.metadataPath).readAsStringSync()) as Map;
      expect(decoded['extrinsic'], isEmpty);
      expect(decoded['is_tracking'], isFalse);
      expect(decoded['trackingStateName'], isNot('normal'));
      expect(CaptureSession.debugIsCompleteArFrameSidecar(decoded), isFalse);
      await provider.dispose();
    });

    test('🔴 原生写的是 HEIC ⇒ native_format_not_jpeg,文件留在原地不改名伪装',
        () async {
      final photo = _FilePhotoApi(tmp, extension: 'heic');
      final provider = _trackingProvider(photo);
      provider.tick();
      final spec = ARFrameSaveSpec(
        frameID: 'tap-3',
        cellIndex: -1,
        slotIndex: -1,
        jpegPath: '${tmp.path}/capture/photos/official_tap-3.jpg',
        metadataPath: '${tmp.path}/capture/photos/official_tap-3.json',
      );
      final res = await provider.saveCurrentFrame(spec);
      expect(res.status, 'native_format_not_jpeg');
      expect(res.saved, isFalse);
      expect(photo.requests, hasLength(1));
      expect(File(photo.writtenPaths.single).existsSync(), isTrue);
      expect(File(spec.jpegPath).existsSync(), isFalse);
      expect(File(spec.metadataPath).existsSync(), isFalse);
      await provider.dispose();
    });

    test('🔴 requestPhoto 串行化:两条并发请求各拿到自己的 requestId,没有一条饿死',
        () async {
      final photo = _FilePhotoApi(tmp);
      final provider = _trackingProvider(photo);
      provider.tick();
      final futures = <Future<ZeroArkitPhotoResult?>>[
        provider.requestPhoto(timeout: const Duration(milliseconds: 300)),
        provider.requestPhoto(timeout: const Duration(milliseconds: 300)),
      ];
      final results = await Future.wait(futures);
      expect(photo.requests, hasLength(2));
      expect(results[0]!.requestId, photo.requests[0]);
      expect(results[1]!.requestId, photo.requests[1]);
      await provider.dispose();
    });
  });

  // ══ (D) captureHighResolutionStill 不拍 ═════════════════════════════════
  group('(D) captureHighResolutionStill', () {
    test('🔴 返回 null 且 capturePhoto 0 次(活让给 saveCurrentFrame)', () async {
      final photo = _FilePhotoApi(tmp);
      final provider = _trackingProvider(photo);
      provider.tick();
      final still = await provider.captureHighResolutionStill(
        highresPath: '${tmp.path}/x.jpg',
        previewPath: '${tmp.path}/x_preview.jpg',
        triggerTimestamp: 1.0,
      );
      expect(still, isNull);
      expect(photo.requests, isEmpty);
      await provider.dispose();
    });
  });

  // ══ (G) 端到端:手动快门 ⇒ 入库 ═════════════════════════════════════════
  group('(G) CaptureSession 手动快门(生产路径)', () {
    late bool archiveWasEnabled;
    setUp(() {
      archiveWasEnabled = CaptureArchiveService.enabled;
      CaptureArchiveService.enabled = false;
    });
    tearDown(() {
      CaptureArchiveService.enabled = archiveWasEnabled;
    });

    test('🔴 xrslam:null still → saveCurrentFrame → sidecar → 提升入库,captureKind=xrslam_frame_fallback_jpeg',
        () async {
      final photo = _FilePhotoApi(tmp);
      final provider = _trackingProvider(photo);
      final session = CaptureSession(
        poseProvider: provider,
        captureDirectoryFactory: () async =>
            Directory('${tmp.path}/capture'),
      );
      await session.start(autoLock: false, manualCapture: true);
      provider.tick();
      expect(session.debugLastPoseSource, 'xrslam');

      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);
      final OfficialHighResReconstructionInput input =
          await capture!.highResolutionCompletion;
      await capture.previewCompletion;

      expect(input.jpegPath, capture.evidenceJpegPath);
      expect(input.imageWidth, 4032);
      expect(input.imageHeight, 3024);
      expect(File(input.jpegPath).existsSync(), isTrue);
      expect(
        capture.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.accepted,
      );
      expect(session.canonicalPhotoSnapshot, hasLength(1));
      final record = session.canonicalPhotoSnapshot.single;
      expect(record.transactionId, capture.transactionId);
      expect(record.captureKind, 'xrslam_frame_fallback_jpeg');
      expect(record.captureKind, isNot(startsWith('arkit')));
      expect(record.evidencePose, hasLength(16));
      for (var i = 0; i < 16; i++) {
        expect(
          record.evidencePose[i],
          closeTo(provider.lastPose!.extrinsic4x4[i], 1e-12),
        );
      }
      // 证据 + 预览各一张:这条路上预览 spec 仍会触发第二次曝光(已知缺口,
      // 见报告);证据本身只拍了一张。
      expect(photo.requests, hasLength(2));
      final sidecar = jsonDecode(
        File(
          capture.evidenceJpegPath.replaceFirst(RegExp(r'\.jpg$'), '.json'),
        ).readAsStringSync(),
      ) as Map;
      expect(sidecar['poseSource'], 'xrslam');

      await session.dispose();
      await provider.dispose();
    });

    test('🔴 阴性对照 —— ARKit 标签的 null still 仍是 captureFailed,不走 fallback',
        () async {
      final provider = _ArkitNullStillProvider();
      final session = CaptureSession(
        poseProvider: provider,
        captureDirectoryFactory: () async =>
            Directory('${tmp.path}/capture'),
      );
      await session.start(autoLock: false, manualCapture: true);
      provider.emitPose();
      expect(session.debugLastPoseSource, 'arkit');

      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);
      await expectLater(
        capture!.highResolutionCompletion,
        throwsA(
          isA<OfficialHighResCaptureException>().having(
            (e) => e.failure,
            'failure',
            OfficialHighResInputFailure.captureFailed,
          ),
        ),
      );
      await capture.previewCompletion;
      expect(provider.highResCalls, 1);
      // saveCurrentFrame 只为预览 spec 调过,证据 spec 一次都没有。
      expect(
        provider.saveSpecs.map((s) => s.jpegPath),
        isNot(contains(capture.evidenceJpegPath)),
      );
      expect(session.canonicalPhotoSnapshot, isEmpty);

      await session.dispose();
    });

    test('🔴 xrslam 成片不是 4032×3024 ⇒ unexpectedDimensions(硬闸不放宽)', () async {
      final photo = _FilePhotoApi(tmp, width: 1920, height: 1440);
      final provider = _trackingProvider(photo);
      final session = CaptureSession(
        poseProvider: provider,
        captureDirectoryFactory: () async =>
            Directory('${tmp.path}/capture'),
      );
      await session.start(autoLock: false, manualCapture: true);
      provider.tick();

      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);
      await expectLater(
        capture!.highResolutionCompletion,
        throwsA(
          isA<OfficialHighResCaptureException>().having(
            (e) => e.failure,
            'failure',
            OfficialHighResInputFailure.unexpectedDimensions,
          ),
        ),
      );
      await capture.previewCompletion;
      expect(session.canonicalPhotoSnapshot, isEmpty);

      await session.dispose();
      await provider.dispose();
    });
  });
}
