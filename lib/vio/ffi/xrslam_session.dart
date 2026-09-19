// xrslam_session.dart —— 引擎会话:建/推 IMU/走一帧/销毁。
//
// ══ 🔴 全文是**复制粘贴**,两个抄源都标在函数上 ═══════════════════════════
//
// A. 建会话 / 销毁 —— 抄**我们自己的** `xrslam_smoke.dart:195-232`
//    (`runXrslamLifecycle`)。
//    🔴 **更正(2026-09-19)**:我最初在这里写"已经在真机上跑通过
//    Create→Destroy" —— 那是**我编的**。grep 实证 `runXrslamLifecycle`
//    **没有任何调用者**,还有一个测试专门断言它不被调用
//    (`vio_diagnostics_privacy_contract_test.dart:123`)。
//    所以它只是"写好了的参考实现",**不是"验证过的实现"**。
//    抄它的那两个坑注释仍然值得抄(见下),但别把它当作已验证的证据。
//    它带着两个坑,其中**第一个它自己写反了**:
//      ① 🔴 **配置参数是文件路径,不是 YAML 正文。**
//         `xrslam_smoke.dart` 的注释说"我们的构建打开了
//         XRSLAM_CONFIG_FROM_STRING ⇒ 是正文不是路径",**反了**。
//         两条实证(2026-09-19,真机 SIGABRT 之后查的):
//           · 出货 receipt 的 compile_flags 全列里**没有**
//             `-DXRSLAM_CONFIG_FROM_STRING`;
//           · `nm -u libxrslam_generic_4beb1a9.a` **引用了 YAML::LoadFile**
//             (`yaml_config.cpp:153-168` 是 `#if defined(...)` 二选一:
//              定义了走 `YAML::Load`(正文),没定义走 `YAML::LoadFile`(路径))。
//         按正文传的后果不是"解析失败返回错误码",而是
//         `LoadFile("%YAML:1.0\n# GENERATED…")` 找不到文件 → yaml-cpp 抛
//         `BadFile` → **穿过 C ABI → std::terminate → SIGABRT**,整个 app 闪退。
//         真机栈:`__cxa_throw / YamlConfig::YamlConfig / XRSLAMCreate + 120`。
//      ② `XRSLAMCreate` 的约定是 **1=成功 / 0=失败**,与同头文件里其它函数
//         (0=OK)**正好相反**。用 `rc >= 0` 判会把失败当成功 ⇒ 必须走
//         [xrslamCreateSucceeded]。
//
// ══ 🔴 这里的 try/catch 接不住引擎的 C++ 异常 ═══════════════════════════════
// Dart 的 try/catch **无法**捕获穿过 C ABI 的 C++ 异常 —— 那是
// `std::terminate`,直接 abort,进程没了。所以下面对 `XRSLAMCreate` 的 catch
// 只能挡住 Dart 侧的错(符号找不到之类),**挡不住引擎内部抛**。
// ⇒ 唯一的防线是**别让它有理由抛**:配置必须先落盘成文件、路径必须存在。
//
// B. 推传感器 / 走一帧 —— 抄**上游自己的 iOS demo**
//    `xrslam-ios/visualizer/src/XRSLAM_iOS.mm:155-210`:
//        XRSLAMGyroscope gyro; gyro.timestamp = t; gyro.data[0..2] = x,y,z;
//        XRSLAMPushSensorData(XRSLAM_SENSOR_GYROSCOPE, &gyro);
//        …
//        XRSLAMPushSensorData(XRSLAM_SENSOR_CAMERA, &image);
//        XRSLAMRunOneFrame();
//
// ══ 🔴 相机帧:**不转灰度**,原样推 BGRA ═══════════════════════════════════
// 引擎自己就接 4 通道 —— `XRSLAMManager.cpp:499`:
//     else if (image->channel == 4) { cv_type = CV_8UC4; elem_size = 4; }
// 转灰度是它内部用**自己那份 OpenCV 4.0.1** 做的。我们在外面再转一次,只会
// 引入一份"与它不逐位一致"的实现 —— 这个代码库为 1 ULP 的像素差栽过
// (pip cv2 的 `-ffp-contract=on` vs 设备端 off,21% 像素差 1 ULP)。
// 我们的 slot 固定 **32BGRA**,与上游 demo 喂的 `CV_8UC4` 同型,直接推即可。
//
// Swift 那边只做它独有的一件事:锁住 CVPixelBuffer 并交出基址
// (`pw_camera_slot_lock` / `pw_camera_slot_unlock`),所以 Swift 侧不需要
// XRSLAM.h,也不用改 pbxproj / 桥接头。
//
// ══ 🔴 出货引擎只导出 5 个符号 ═════════════════════════════════════════════
// nm 核过 `libxrslam_generic_4beb1a9.a`,与 receipt 的 exported_abi 一致:
//     XRSLAMCreate  XRSLAMDestroy  XRSLAMGetResult
//     XRSLAMPushSensorData  XRSLAMRunOneFrame
// 本文件只用这五个里的四个(读位姿在 `engine_pose_poller.dart` 用第五个)。
// 任何"绑定里有、归档里没有"的符号都不能用 —— 我为此吃过一次链接错误。

import 'dart:ffi' as ffi;
import 'dart:io' as io;

import 'package:ffi/ffi.dart';

import '../pose/gravity_attitude.dart' show ImuSample;
import 'xrslam_bindings.dart';
import 'xrslam_config.dart';
import 'xrslam_status.dart';

/// 会话建立的结果。失败时 [error] 一定非空 —— 不静默返回一个"看起来能用"的实例。
class XrslamSessionStart {
  const XrslamSessionStart({required this.createRc, required this.error});

  /// `XRSLAMCreate` 的原始返回码。🔴 **1=成功**,别用 `>= 0` 判。
  final int? createRc;
  final String? error;

  bool get ok => error == null;
}

/// 一个 XRSLAM 会话。**进程内只能有一个** —— 上游的 Detail 是单例,
/// `XRSLAMCreate` 二次调用不是"再建一个",而是覆盖。
class XrslamSession {
  XrslamSession._(this._bindings);

  final XrslamBindings _bindings;
  bool _destroyed = false;

  static XrslamSession? _current;

  /// 当前会话;没建过就是 `null`。
  static XrslamSession? get current => _current;

  /// 建会话。**抄 `xrslam_smoke.dart` 的 runXrslamLifecycle**,只是不立刻 Destroy。
  ///
  /// [intrinsics] 不传就用那边同一组**明确标记为占位**的值;真实值要从
  /// `AVCameraCalibrationData` 读(`PwCameraSlot.intrinsics` 能给)。
  static XrslamSessionStart start({CameraIntrinsics? intrinsics}) {
    if (_current != null) {
      return const XrslamSessionStart(
        createRc: null,
        error: '已有会话在跑 —— 上游 Detail 是单例,二次 Create 是覆盖不是新建',
      );
    }

    final CameraIntrinsics k = intrinsics ??
        const CameraIntrinsics(
          fx: 1000.0,
          fy: 1000.0,
          cx: 640.0,
          cy: 360.0,
          resolutionWidth: 1280,
          resolutionHeight: 720,
          provenance: FieldProvenance.placeholder,
        );
    final XrslamConfigBuilder builder = XrslamConfigBuilder(intrinsics: k);

    final XrslamBindings bindings;
    try {
      bindings = XrslamBindings(ffi.DynamicLibrary.process());
    } catch (e) {
      // 整个 app 没链 XRSLAM,或符号被 dead-strip。与 engine_pose_poller 同口径:
      // 这是**降级**,不是崩溃 —— 上层照样能跑静止兜底。
      return XrslamSessionStart(createRc: null, error: '找不到 XRSLAM 符号: $e');
    }

    // ① 落盘成文件,传**路径**(见文件头 ①)。
    //   写进 systemTemp:iOS 上它是 NSTemporaryDirectory(),应用沙盒内可写。
    final String? cfgErr = _writeConfigs(builder);
    if (cfgErr != null) {
      return XrslamSessionStart(createRc: null, error: cfgErr);
    }
    final ffi.Pointer<ffi.Char> slamCfg =
        _slamPath!.toNativeUtf8().cast<ffi.Char>();
    final ffi.Pointer<ffi.Char> devCfg =
        _devPath!.toNativeUtf8().cast<ffi.Char>();
    final ffi.Pointer<ffi.Char> license = ''.toNativeUtf8().cast<ffi.Char>();
    final ffi.Pointer<ffi.Char> product =
        'pocketworld'.toNativeUtf8().cast<ffi.Char>();
    final ffi.Pointer<ffi.Pointer<ffi.Void>> cfgOut =
        calloc<ffi.Pointer<ffi.Void>>();

    int? rc;
    String? err;
    try {
      rc = bindings.XRSLAMCreate(slamCfg, devCfg, license, product, cfgOut);
      // ② 1=成功。用常规的 rc>=0 会把失败当成功。
      if (xrslamCreateSucceeded(rc)) {
        _current = XrslamSession._(bindings);
      } else {
        err = 'XRSLAMCreate 返回 $rc(约定 1=成功);cfgOut=${cfgOut.value.address}';
      }
    } catch (e) {
      err = 'XRSLAMCreate threw: $e';
    } finally {
      calloc.free(slamCfg);
      calloc.free(devCfg);
      calloc.free(license);
      calloc.free(product);
      calloc.free(cfgOut);
    }
    return XrslamSessionStart(createRc: rc, error: err);
  }

  static String? _slamPath;
  static String? _devPath;

  /// 把两份配置写成文件,返回 `null` 表示成功、否则返回错误说明。
  ///
  /// 🔴 **必须在调 XRSLAMCreate 之前成功** —— 路径不存在时引擎会抛 C++ 异常,
  /// 而那个异常会直接 abort 掉整个进程(见文件头)。所以这里失败就**不建会话**。
  static String? _writeConfigs(XrslamConfigBuilder builder) {
    try {
      final io.Directory dir = io.Directory(
          '${io.Directory.systemTemp.path}/pw_xrslam_cfg')
        ..createSync(recursive: true);
      final io.File slam = io.File('${dir.path}/slam_config.yaml');
      final io.File dev = io.File('${dir.path}/device_config.yaml');
      slam.writeAsStringSync(builder.buildSlamConfigYaml(), flush: true);
      dev.writeAsStringSync(builder.buildDeviceConfigYaml(), flush: true);
      // 再确认一次真的落了盘 —— 引擎读不到就是 abort,不是返回错误码,
      // 这一步的代价远低于一次闪退。
      if (!slam.existsSync() || !dev.existsSync()) {
        return '配置文件写了但读不到:${slam.path} / ${dev.path}';
      }
      _slamPath = slam.path;
      _devPath = dev.path;
      return null;
    } catch (e) {
      return '写配置文件失败: $e';
    }
  }

  /// 推一条 IMU。抄上游 `XRSLAM_iOS.mm:190-210` —— 陀螺与加速度**分两次推**,
  /// 各自带自己的时间戳。
  ///
  /// 🔴 顺序:上游是先陀螺后加速度。这里保持一致 —— 预积分对到达顺序敏感。
  void pushImu(ImuSample s) {
    if (_destroyed) return;
    final ffi.Pointer<XRSLAMGyroscope> gyro = calloc<XRSLAMGyroscope>();
    final ffi.Pointer<XRSLAMAcceleration> acc = calloc<XRSLAMAcceleration>();
    try {
      gyro.ref.timestamp = s.timestampSeconds;
      gyro.ref.data[0] = s.gx;
      gyro.ref.data[1] = s.gy;
      gyro.ref.data[2] = s.gz;
      _bindings.XRSLAMPushSensorData(
          XRSLAMSensorType.XRSLAM_SENSOR_GYROSCOPE, gyro.cast<ffi.Void>());

      acc.ref.timestamp = s.timestampSeconds;
      acc.ref.data[0] = s.ax;
      acc.ref.data[1] = s.ay;
      acc.ref.data[2] = s.az;
      _bindings.XRSLAMPushSensorData(
          XRSLAMSensorType.XRSLAM_SENSOR_ACCELERATION, acc.cast<ffi.Void>());
    } finally {
      calloc.free(gyro);
      calloc.free(acc);
    }
  }

  /// 推一帧相机图像并走一帧。抄上游 `XRSLAM_iOS.mm:151-167`。
  ///
  /// [pixelBufferAddress] 来自 `PwCameraSlot.acquire()`(已 retain 的
  /// CVPixelBufferRef 地址);本函数**不负责 release**,那仍由调用方配对。
  ///
  /// 返回是否真的推了一帧。
  bool pushCameraFrame({
    required int pixelBufferAddress,
    required double timestampSeconds,
  }) {
    if (_destroyed || pixelBufferAddress == 0) return false;
    final ffi.Pointer<ffi.Uint64> info = calloc<ffi.Uint64>(4);
    final ffi.Pointer<XRSLAMImage> img = calloc<XRSLAMImage>();
    bool locked = false;
    try {
      if (_lock(pixelBufferAddress, info) != 0) return false;
      locked = true;
      final int base = info[0];
      if (base == 0) return false;

      // 🔴 `calloc` 已经零初始化。上游那行注释写着 "必须零初始化:
      //    width/height 是末尾新增字段" —— 不清零会把栈垃圾当分辨率。
      img.ref.data = ffi.Pointer<ffi.UnsignedChar>.fromAddress(base);
      img.ref.timeStamp = timestampSeconds;
      img.ref.stride = info[1]; // 字节/行,与 cv::Mat::step[0] 同义
      img.ref.camera_id = 0;
      img.ref.channel = 4; // 🔴 BGRA 原样推,引擎内部转灰度
      img.ref.width = info[2];
      img.ref.height = info[3];
      img.ref.ext = ffi.nullptr;

      _bindings.XRSLAMPushSensorData(
          XRSLAMSensorType.XRSLAM_SENSOR_CAMERA, img.cast<ffi.Void>());
      _bindings.XRSLAMRunOneFrame();
      return true;
    } catch (_) {
      return false;
    } finally {
      // 🔴 锁必须解 —— 漏解会把相机线程卡死。
      if (locked) _unlock(pixelBufferAddress);
      calloc.free(info);
      calloc.free(img);
    }
  }

  static final int Function(int, ffi.Pointer<ffi.Uint64>) _lock =
      ffi.DynamicLibrary.process().lookupFunction<
          ffi.Int32 Function(ffi.Uint64, ffi.Pointer<ffi.Uint64>),
          int Function(int, ffi.Pointer<ffi.Uint64>)>('pw_camera_slot_lock');

  static final void Function(int) _unlock =
      ffi.DynamicLibrary.process().lookupFunction<
          ffi.Void Function(ffi.Uint64),
          void Function(int)>('pw_camera_slot_unlock');

  /// 只走一帧,不推图像。给"没有新帧但想让引擎消化 IMU"的场合。
  void runOneFrame() {
    if (_destroyed) return;
    _bindings.XRSLAMRunOneFrame();
  }

  /// 销毁。**必须调** —— 上游 Detail 是进程级单例,不销毁下一次 Create 会覆盖。
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    if (identical(_current, this)) _current = null;
    try {
      _bindings.XRSLAMDestroy();
    } catch (_) {
      // 销毁失败不上抛:调用方通常在 dispose 里调,抛出去会盖掉真正的错误。
    }
  }

  bool get isAlive => !_destroyed;
}
