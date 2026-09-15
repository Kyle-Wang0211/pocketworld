// xrslam_config.dart — 运行时生成 XRSLAM 的两份 YAML 配置。
//
// 为什么是运行时生成:
//   上游的做法是**逐机型 yaml**(xrslam-ios/visualizer/configs 下 18 个 iPhone
//   文件、Android 侧 0 个),而且那 18 个里 iPhone 16e 与 iPhone 14 Pro 的
//   intrinsics 和 p_bc **逐字节相同** —— 是占位拷贝,根本没标定过。
//   商汤自家 xrapi 按 brand/model 查表,而它的 SLAM 总共只支持 4 台安卓手机。
//   我们的硬需求是「一套管线服务所有手机,绝不逐机型实测」,所以走的是
//   **运行时自证**:能从系统 API 读的就读,读不到的显式标记来源,
//   让「哪些是测的、哪些是假设的」永远可见,而不是混在一份 yaml 里假装都可信。
//
// Dart 把两份正文逐字节写进会话私有临时文件。官方 generic 分支保持原样走
// YAML::LoadFile；Swift/Kotlin 只把路径搬到五函数 C ABI，不解析也不判参数。
//
// ⚠️ 14 个必需字段里有 2 个在 iOS 上**没有任何系统 API**:
//   • cam0.extrinsic.q_bc / p_bc(相机-IMU 外参)—— 真缺口。ARKit 内部知道
//     但不暴露。xrapi 里 default 与 huawei/p40 的 p_bc 差 12mm,说明它是
//     逐机型的。这条要么在线估(需要扩误差状态),要么接受精度损失。
//   • imu.noise 四个协方差 —— 但 xrapi 的 default 与 huawei/p40 这 8 个数
//     **完全相同**,说明它不强依赖机型,用共享默认值是有依据的。

import 'xrslam_extrinsics.dart';

/// 一个配置字段的来源。写进 yaml 注释,也进遥测 —— 我们必须随时能回答
/// 「这次跑用的内参是量出来的还是编的」。
enum FieldProvenance {
  /// 从系统 API 读到的(如 AVCameraCalibrationData)。
  deviceApi,

  /// 我们自己在这台机上测出来的。
  measured,

  /// 行业/上游共享默认值,有依据但不是这台机的。
  sharedDefault,

  /// 占位,**没有依据**。任何用到它的结果都不能报绝对精度。
  placeholder,
}

extension FieldProvenanceLabel on FieldProvenance {
  String get label => switch (this) {
    FieldProvenance.deviceApi => 'device-api',
    FieldProvenance.measured => 'measured',
    FieldProvenance.sharedDefault => 'shared-default',
    FieldProvenance.placeholder => 'PLACEHOLDER',
  };
}

/// iOS 平台层的版本化原始内参 DTO。
///
/// Swift 每帧只保留一个 3x3 值类型和两个原始尺寸;只在 Dart 主动
/// 调用 `latestIntrinsics` 时才把这 11 个数走 MethodChannel。整帧像素
/// 从不经 Flutter,因此不会为跨端判定引入 2.7 MB/帧的搬运。
class IosRawCameraIntrinsics {
  const IosRawCameraIntrinsics._({
    required this.sessionId,
    required this.sessionEpoch,
    required this.sessionGeneration,
    required this.intrinsicMatrixColumnMajor,
    required this.imageResolutionWidth,
    required this.imageResolutionHeight,
    required this.source,
    required this.referenceTrackingState,
    required this.referenceTrackingReason,
  });

  final String sessionId;
  final int sessionEpoch;
  final int sessionGeneration;
  final List<double> intrinsicMatrixColumnMajor;
  final double imageResolutionWidth;
  final double imageResolutionHeight;
  final String source;
  final String referenceTrackingState;
  final String referenceTrackingReason;

  static IosRawCameraIntrinsics? fromWire(Map<String, Object?>? wire) {
    if (wire == null) return null;
    const Set<String> exactKeys = <String>{
      'schema',
      'sessionId',
      'sessionEpoch',
      'sessionGeneration',
      'intrinsicMatrixColumnMajor',
      'imageResolutionWidth',
      'imageResolutionHeight',
      'source',
      'referenceTrackingState',
      'referenceTrackingReason',
    };
    if (wire.length != exactKeys.length ||
        !wire.keys.every(exactKeys.contains) ||
        wire['schema'] != 'pw.vio.ios.intrinsics-raw/1' ||
        wire['sessionId'] is! String ||
        (wire['sessionId']! as String).isEmpty ||
        wire['sessionEpoch'] is! int ||
        (wire['sessionEpoch']! as int) < 0 ||
        wire['sessionGeneration'] is! int ||
        (wire['sessionGeneration']! as int) <= 0 ||
        wire['source'] is! String ||
        wire['referenceTrackingState'] is! String ||
        wire['referenceTrackingReason'] is! String) {
      return null;
    }

    final Object? matrixWire = wire['intrinsicMatrixColumnMajor'];
    if (matrixWire is! List || matrixWire.length != 9) return null;
    final List<double> matrix = <double>[];
    for (final Object? element in matrixWire) {
      if (element is! num) return null;
      final double value = element.toDouble();
      if (!value.isFinite) return null;
      matrix.add(value);
    }

    double? finiteDimension(String key) {
      final Object? raw = wire[key];
      if (raw is! num) return null;
      final double value = raw.toDouble();
      return value.isFinite ? value : null;
    }

    final double? width = finiteDimension('imageResolutionWidth');
    final double? height = finiteDimension('imageResolutionHeight');
    if (width == null || height == null) return null;

    return IosRawCameraIntrinsics._(
      sessionId: wire['sessionId']! as String,
      sessionEpoch: wire['sessionEpoch']! as int,
      sessionGeneration: wire['sessionGeneration']! as int,
      intrinsicMatrixColumnMajor: List<double>.unmodifiable(matrix),
      imageResolutionWidth: width,
      imageResolutionHeight: height,
      source: wire['source']! as String,
      referenceTrackingState: wire['referenceTrackingState']! as String,
      referenceTrackingReason: wire['referenceTrackingReason']! as String,
    );
  }
}

/// 相机内参。fx/fy/cx/cy 单位是像素,对应 [resolutionWidth]×[resolutionHeight]。
class CameraIntrinsics {
  const CameraIntrinsics({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.resolutionWidth,
    required this.resolutionHeight,
    required this.provenance,
  });

  final double fx, fy, cx, cy;
  final int resolutionWidth, resolutionHeight;
  final FieldProvenance provenance;

  /// 从原生侧 `latestIntrinsics` 的 wire map 构造。
  ///
  /// 只有拿到**全部**四个内参加分辨率才返回非 null —— 缺一个就返回 null,
  /// 让调用方如实落到 PLACEHOLDER。半真半假的内参比明确的占位更危险:
  /// 前者会让人以为这次跑是标定过的。
  static CameraIntrinsics? fromWire(Map<String, Object?>? m) {
    final IosRawCameraIntrinsics? raw = IosRawCameraIntrinsics.fromWire(m);
    if (raw == null ||
        raw.source != 'ARCamera.intrinsics' ||
        raw.referenceTrackingState != 'normal' ||
        raw.referenceTrackingReason != 'none') {
      return null;
    }

    final double rawWidth = raw.imageResolutionWidth;
    final double rawHeight = raw.imageResolutionHeight;
    if (rawWidth <= 0 ||
        rawHeight <= 0 ||
        rawWidth != rawWidth.truncateToDouble() ||
        rawHeight != rawHeight.truncateToDouble()) {
      return null;
    }
    final int w = rawWidth.toInt();
    final int h = rawHeight.toInt();

    // simd_float3x3 的 wire 是列主序:
    // [m00,m10,m20, m01,m11,m21, m02,m12,m22]。元素选择只在 Dart。
    final List<double> matrix = raw.intrinsicMatrixColumnMajor;
    final double fx = matrix[0];
    final double fy = matrix[4];
    final double cx = matrix[6];
    final double cy = matrix[7];

    // 物理合理性和追踪可用性也只在 Dart 选择。
    if (fx <= 0 || fy <= 0 || cx < 0 || cx >= w || cy < 0 || cy >= h) {
      return null;
    }
    return CameraIntrinsics(
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      resolutionWidth: w,
      resolutionHeight: h,
      provenance: FieldProvenance.deviceApi,
    );
  }

  /// ⚠️ 内参与分辨率是绑定的。同一台机换个采集分辨率,fx/cx 必须等比缩放,
  /// 否则整条位姿链系统性错 —— 而且不会报错。
  CameraIntrinsics scaledTo(int w, int h) {
    final double sx = w / resolutionWidth;
    final double sy = h / resolutionHeight;
    return CameraIntrinsics(
      fx: fx * sx,
      fy: fy * sy,
      cx: cx * sx,
      cy: cy * sy,
      resolutionWidth: w,
      resolutionHeight: h,
      provenance: provenance,
    );
  }
}

/// 相机-IMU 外参。iOS 上**没有任何 API 提供它**。
class CameraImuExtrinsic {
  const CameraImuExtrinsic({
    required this.qbc,
    required this.pbc,
    required this.provenance,
  });

  /// 四元数 [x, y, z, w]。
  final List<double> qbc;

  /// 平移 [x, y, z],单位米。
  final List<double> pbc;

  final FieldProvenance provenance;

  /// iPhone 的保守默认:相机与 IMU 同轴、零平移。
  ///
  /// 🔴 **这是占位,不是标定值。** 真实值是逐机型的 —— xrapi 里 default 与
  /// huawei/p40 的 p_bc 差 12mm。12mm 的外参误差在 2m 物距上约 0.6% 的尺度
  /// 影响,正好吃掉我们「进 1%」的预算一大半。
  /// 用它跑出来的结果**不能报绝对尺寸**。
  static const CameraImuExtrinsic iosPlaceholder = CameraImuExtrinsic(
    qbc: <double>[0.0, 0.0, 0.0, 1.0],
    pbc: <double>[0.0, 0.0, 0.0],
    provenance: FieldProvenance.placeholder,
  );

  /// 按 `hw.machine`(如 iPhone15,2)取上游标定的相机-IMU 外参。
  ///
  /// 🔴 **不要再用 [iosPlaceholder]**。它填的是单位四元数,而真值是 180° 翻转
  /// —— 真机实测那样喂 5731 帧一个位姿都出不来(slamState 恒 0)。
  /// 它保留在这里只是为了让"没查表就跑"这件事在 provenance 里显形。
  ///
  /// 旋转对所有 iPhone 相同(18/18 实证),平移查表;查不到用分量中位数,
  /// 代价是几厘米杠杆臂 —— 有界,且远小于朝向错误。
  static CameraImuExtrinsic forIosMachine(String? machine) {
    final List<double>? p = machine == null ? null : kIosCameraImuPbc[machine];
    return CameraImuExtrinsic(
      qbc: kIosCameraImuQbc,
      pbc: p ?? kIosCameraImuPbcFallback,
      // 三态,不是两态 —— 遥测里必须能区分"真标定 / 上游拷贝的 / 我们回退的":
      //   deviceApi      查到且是上游真标定值
      //   placeholder    查到但上游那份是从别的机型逐字节拷来的(目前只有 16e)
      //   sharedDefault  查不到,用 18 个已知值的分量中位数
      provenance: p == null
          ? FieldProvenance.sharedDefault
          : (machine != null && kIosCameraImuPbcCopied.contains(machine)
                ? FieldProvenance.placeholder
                : FieldProvenance.deviceApi),
    );
  }
}

/// IMU 噪声模型。连续时间噪声密度 → 离散协方差由核内按实测 dt 生成。
class ImuNoise {
  const ImuNoise({
    required this.covG,
    required this.covA,
    required this.covBg,
    required this.covBa,
    required this.provenance,
  });

  final double covG, covA, covBg, covBa;
  final FieldProvenance provenance;

  /// OpenXRLab 官方 iOS 配置值。
  ///
  /// 冻结上游 `4beb1a9` 的 18 份 iPhone YAML 对这四个协方差逐字相同；
  /// 官方复刻臂必须整套使用，不能把 bias random walk 换成别处的通用默认。
  static const ImuNoise sharedMems = ImuNoise(
    covG: 2.8791302399999997e-08,
    covA: 4.0e-6,
    covBg: 3.7608844899999997e-10,
    covBa: 9.0e-6,
    provenance: FieldProvenance.sharedDefault,
  );
}

/// 生成 XRSLAMCreate 需要的两份 YAML。
class XrslamConfigBuilder {
  const XrslamConfigBuilder({
    required this.intrinsics,
    this.extrinsic = CameraImuExtrinsic.iosPlaceholder,
    this.imuNoise = ImuNoise.sharedMems,
    this.cameraTimeOffsetSeconds = 0.0,
    this.cameraTimeOffsetProvenance = FieldProvenance.placeholder,
    this.pixelNoiseVariance = 0.5,
    this.slidingWindowSize = 5,
    this.solverTimeLimitSeconds = 0.1,
    this.solverIterationLimit = 10,
  });

  final CameraIntrinsics intrinsics;
  final CameraImuExtrinsic extrinsic;
  final ImuNoise imuNoise;

  /// cam0.time_offset。我们实测 ARFrame 与 CoreMotion 的**投递延迟**差
  /// 34.76 ms,但那是观测延迟不是时间戳偏置 —— 两路时间戳同域且都是采集时刻,
  /// 所以这里默认 0,除非有真正的标定值。
  final double cameraTimeOffsetSeconds;
  final FieldProvenance cameraTimeOffsetProvenance;

  /// 关键点观测噪声方差,单位 **pixel²**。写进 yaml 是个 2×2 协方差矩阵,
  /// 不是标量 —— 写成标量会被 assign_matrix 判成类型错误,
  /// XRSLAMCreate 直接返回 0。上游 euroc 用的是 0.5。
  final double pixelNoiseVariance;
  // [pw] 2026-08-23 撤回:曾经在这里按分辨率等比缩放 min_parallax /
  // min_keypoint_distance,依据是"VIO 参数按 VGA 调的"。**那条依据不成立** ——
  // VGA 只是 1987 年 IBM 的显示标准,不是任何算法团队的结论。
  //
  // 上游自己的两份配置直接反证:
  //     参数                    euroc 752x480   iphone 640x480
  //     min_parallax                10.0            10.0      <- 跨分辨率不动
  //     min_keypoint_distance       20.0            25.0      <- 反方向
  //     max_keypoint_detection       200             300
  // 作者跨 1.175x 的分辨率差把 min_parallax 保持不变,min_keypoint_distance
  // 甚至随分辨率下降而调大。=> 上游不存在"像素参数随分辨率缩放"这条规律,
  // 那是我自己发明的。按"能复刻就复刻",这里逐字沿用上游 iPhone 配置。
  //
  // ⚠️ 仍未消除的风险:超出作者验证过的 1.175x 区间。
  //
  // [pw] 2026-09-14 更正上面这段风险描述 —— 原文两处都错,已逐行核上游
  // 源码(本地 ~/Developer/xrslam-4beb1a9-thr,即我们锁的 revision):
  //   ① **不是关键帧门槛,是初始化器门槛。** `initializer_min_parallax` 全仓
  //      只用在一处:core/initializer.cpp:262 `if (total_parallax < it) return false;`
  //      —— 初始化的最小运动要求。关键帧选取不读它。
  //   ② **方向是「更松」不是「更严」。** total_parallax 由 initializer.cpp:250-253
  //      的 apply_k() 算出,而 stereo.h:8 的
  //      `apply_k(p,K) = {p.x/p.z*K(0,0)+K(0,2), ...}` 乘的是 **fx**
  //      ⇒ 单位是像素,随分辨率线性放大。分辨率 ×N 后,同样的实际运动产生
  //      N 倍像素视差,`< 10` 只需 1/N 的实际运动即可通过 ⇒ **初始化会在
  //      基线不足时被接受**,初始几何条件更差。
  //   ③ 另需修正上面"两份配置互相印证"的立论:min_parallax **不在 YAML 里**,
  //      是 config.cpp:44 写死的 `return 10;`,且无 YAML 子类覆盖。所以那不是
  //      两次独立验证,是同一个编译期常数 —— 也意味着**我们改不动它**,
  //      要改得重建引擎。
  //   ④ "上游没有数据背书"的准确含义:上游从未在 3x 分辨率上跑过,**方向**
  //      现在从源码定死了,**量级**(损失多少精度)仍需实测。

  final int slidingWindowSize;
  final double solverTimeLimitSeconds;
  final int solverIterationLimit;

  /// 每个字段的来源清单 —— 进遥测,让「这次跑用的是测的还是编的」可查。
  Map<String, String> provenanceReport() => <String, String>{
    'cam0.intrinsics': intrinsics.provenance.label,
    'cam0.resolution': intrinsics.provenance.label,
    'cam0.extrinsic': extrinsic.provenance.label,
    'cam0.time_offset': cameraTimeOffsetProvenance.label,
    'imu.noise': imuNoise.provenance.label,
    'pixel_params':
        'upstream-verbatim (min_parallax=10.0, '
        'min_keypoint_distance=25.0) @ ${intrinsics.resolutionWidth}px; '
        '上游验证区间是 640-752px,本次超出',
  };

  /// 有没有任何字段是无依据的占位。true ⇒ **交付层不得报绝对尺寸**。
  bool get hasPlaceholders =>
      provenanceReport().values.contains(FieldProvenance.placeholder.label);

  String buildDeviceConfigYaml() {
    final CameraIntrinsics k = intrinsics;
    String m3(double v) =>
        '$v, 0.0, 0.0,\n          0.0, $v, 0.0,\n          0.0, 0.0, $v';
    return '''
%YAML:1.0
# GENERATED at runtime by XrslamConfigBuilder — 不要落盘成"机型配置文件",
# 那正是我们要避免的东西。每个字段的来源标在行尾。
imu:
  extrinsic:
    q_bi: [ 0.0, 0.0, 0.0, 1.0 ]   # 单位四元数:IMU 即 body 系
    p_bi: [ 0.0, 0.0, 0.0 ]
  noise:
    # 来源:${imuNoise.provenance.label}
    cov_g: [
          ${m3(imuNoise.covG)}]
    cov_a: [
          ${m3(imuNoise.covA)}]
    cov_bg: [
          ${m3(imuNoise.covBg)}]
    cov_ba: [
          ${m3(imuNoise.covBa)}]
cam0:
  # 来源:${k.provenance.label}
  intrinsics: [ ${k.fx}, ${k.fy}, ${k.cx}, ${k.cy} ]
  resolution: [ ${k.resolutionWidth}, ${k.resolutionHeight} ]
  # ARKit 交出的是已校正帧 ⇒ 无畸变
  camera_distortion_flag: 0
  distortion: [ 0.0, 0.0, 0.0, 0.0 ]
  # 2×2 关键点噪声协方差 [pixel²] —— 必须是矩阵,标量会被判类型错
  noise: [
    $pixelNoiseVariance, 0.0,
    0.0, $pixelNoiseVariance]
  # 来源:${cameraTimeOffsetProvenance.label}
  time_offset: $cameraTimeOffsetSeconds
  extrinsic:
    # 来源:${extrinsic.provenance.label}
    # ⚠️ placeholder 意味着这不是标定值。iOS 无任何 API 提供相机-IMU 外参。
    q_bc: [ ${extrinsic.qbc.join(', ')} ]
    p_bc: [ ${extrinsic.pbc.join(', ')} ]
''';
  }

  String buildSlamConfigYaml() =>
      '''
%YAML:1.0
# GENERATED at runtime by XrslamConfigBuilder。
output:
  q_bo: [ 0, 0, 0, 1 ]
  p_bo: [ 0, 0, 0 ]
feature_tracker:
  max_frames: 100
  # OpenXRLab iOS slam_params.yaml @ 4beb1a9，逐项复刻。
  min_keypoint_distance: 25.0
  max_keypoint_detection: 300
solver:
  time_limit: $solverTimeLimitSeconds
  iteration_limit: $solverIterationLimit
sliding_window:
  size: $slidingWindowSize
  tracker_frequent: 3
visual_localization:
  # 永远关闭:上游默认会把图像明文外发到硬编码内网地址
  enable: false
  port: 12345
initializer:
  # [pw] 逐字沿用上游:euroc 与 iphone 两份配置都是 10.0。
  min_parallax: 10.0
parsac:
  parsac_flag: false
  dynamic_probability: 0.15
  threshold: 1.0
  norm_scale: 1.0
  keyframe_check_size: 1
''';
}
