import '../vio/capture/photo_size_rule.dart';
import 'device_pose_trust.dart';

enum OfficialHighResInputFailure {
  captureFailed,
  /// 宽或高 <= 0(读不出尺寸)。
  unexpectedDimensions,
  /// [ENTRY-ANY-4X3 2026-09-25] 下面三个取代原来「不是 4032×3024」这一个码,
  /// 与核外壳 pwofficial_photo_size_status_v1 的 2 / 3 / 4 一一对应。
  /// 原始像素网格不是 4:3(例:16:9)。
  photoNotFourByThree,
  /// 是 4:3,但长边 < 1920(最上游输入必须清晰)。
  photoLongSideBelowMin,
  /// 像素被转成了竖向(3:4)存放:与同帧内参、稠密模型分辨率对不上。
  photoNotSensorOrientation,
  outOfSync,
  missingPose,
  missingIntrinsics,
  missingJpeg,
  actualStillMissingEvidence,
  actualStillQualityRejected,
  actualStillDuplicate,
}

class OfficialHighResInputValidation {
  const OfficialHighResInputValidation.accepted(this.input) : failure = null;

  const OfficialHighResInputValidation.rejected(this.failure) : input = null;

  final OfficialHighResReconstructionInput? input;
  final OfficialHighResInputFailure? failure;

  bool get isAccepted => input != null;
}

class OfficialHighResReconstructionInput {
  const OfficialHighResReconstructionInput._({
    required this.jpegPath,
    required this.imageWidth,
    required this.imageHeight,
    required this.triggerTimestamp,
    required this.captureTimestamp,
    required this.cameraTransform,
    required this.intrinsics,
    required this.devicePoseTrust,
    this.deviceSessionId,
  });

  // [ENTRY-ANY-4X3 2026-09-25] 原来是 `requiredWidth = 4032` / `requiredHeight = 3024`
  // (7410bb9「same-frame 12 MP ARKit inputs」:只收原生高清事务的产物,防误喂 1920x1440
  // 预览帧)。用户改判「只要是 4:3 都行,取各机 4:3 最大尺寸」;防误喂的用意由长边 >= 1920
  // 接住,判据一处定义在 lib/vio/capture/photo_size_rule.dart(与核外壳同一份)。

  /// 判据结果 → 失败码;通过返回 null。
  static OfficialHighResInputFailure? dimensionFailure(int width, int height) =>
      switch (photoSizeVerdict(width, height)) {
        PhotoSizeVerdict.ok => null,
        PhotoSizeVerdict.invalid => OfficialHighResInputFailure.unexpectedDimensions,
        PhotoSizeVerdict.notFourByThree =>
          OfficialHighResInputFailure.photoNotFourByThree,
        PhotoSizeVerdict.longSideBelowMin =>
          OfficialHighResInputFailure.photoLongSideBelowMin,
        PhotoSizeVerdict.notSensorOrientation =>
          OfficialHighResInputFailure.photoNotSensorOrientation,
      };

  final String jpegPath;
  final int imageWidth;
  final int imageHeight;
  final double triggerTimestamp;
  final double captureTimestamp;
  final List<double> cameraTransform;
  final List<double> intrinsics;

  /// [DEVICE-POSE-TRUST 2026-09-24] 追踪器是否承认 [cameraTransform] 所属那一帧
  /// 的位姿(见 device_pose_trust.dart)。**不参与接受/拒绝**:不可信的照片
  /// 照样是合法输入、照样喂 SfM,只是核不得把它摆在这个位姿上。
  final DevicePoseTrust devicePoseTrust;

  bool get devicePoseTrusted => devicePoseTrust.trusted;

  /// [DEVICE-SESSION 2026-09-24](B)这张照片的设备位姿来自哪个跟踪会话
  /// (ARKit run / XRSLAM create;见 device_pose_session.dart)。null = 没有记录。
  final String? deviceSessionId;

  /// 同一张照片、盖上会话归属;不在参考会话里 ⇒ 信任位收紧为 false
  /// ([DevicePoseTrust.notInReferenceSession])。只收紧,不放宽。
  OfficialHighResReconstructionInput withDevicePoseSession({
    required String? deviceSessionId,
    required bool devicePoseTrusted,
  }) => OfficialHighResReconstructionInput._(
    jpegPath: jpegPath,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    triggerTimestamp: triggerTimestamp,
    captureTimestamp: captureTimestamp,
    cameraTransform: cameraTransform,
    intrinsics: intrinsics,
    devicePoseTrust: devicePoseTrusted
        ? devicePoseTrust
        : devicePoseTrust.notInReferenceSession(),
    deviceSessionId: deviceSessionId,
  );

  double get timestampDeltaSeconds =>
      (captureTimestamp - triggerTimestamp).abs();

  static OfficialHighResInputValidation validate({
    required String jpegPath,
    required int imageWidth,
    required int imageHeight,
    required double triggerTimestamp,
    required double captureTimestamp,
    required List<double> cameraTransform,
    required List<double> intrinsics,
    // 原生高清帧自己那一帧的追踪状态(HighResolutionStillCapture
    // .trackingStateName)。缺省 null ⇒ 不可信(fail-closed)。
    String? trackingStateName,
  }) {
    if (jpegPath.isEmpty ||
        !(jpegPath.toLowerCase().endsWith('.jpg') ||
            jpegPath.toLowerCase().endsWith('.jpeg'))) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.missingJpeg,
      );
    }
    final dimensionFailure_ = dimensionFailure(imageWidth, imageHeight);
    if (dimensionFailure_ != null) {
      return OfficialHighResInputValidation.rejected(dimensionFailure_);
    }
    // `captureHighResolutionFrame` completes the exact native request that
    // created this input, and image/pose/intrinsics/timestamp all come from
    // that one returned ARFrame. The request-to-frame delta is camera pipeline
    // latency (250 ms median and up to 1.23 s on the target iPhone), not a
    // measure of image/pose synchronization. Keep both clocks for audit, but
    // never reject a valid transaction merely because the sensor was slow.
    if (!triggerTimestamp.isFinite || !captureTimestamp.isFinite) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.outOfSync,
      );
    }
    if (cameraTransform.length != 16 ||
        cameraTransform.any((value) => !value.isFinite)) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.missingPose,
      );
    }
    if (intrinsics.length < 4 ||
        intrinsics.take(4).any((value) => !value.isFinite || value <= 0)) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.missingIntrinsics,
      );
    }
    return OfficialHighResInputValidation.accepted(
      OfficialHighResReconstructionInput._(
        jpegPath: jpegPath,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        triggerTimestamp: triggerTimestamp,
        captureTimestamp: captureTimestamp,
        cameraTransform: List<double>.unmodifiable(cameraTransform),
        intrinsics: List<double>.unmodifiable(intrinsics.take(4)),
        devicePoseTrust: DevicePoseTrust.fromTrackerState(trackingStateName),
      ),
    );
  }
}
