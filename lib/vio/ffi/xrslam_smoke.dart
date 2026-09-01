// xrslam_smoke.dart — FFI 通路的最小验证。
//
// 为什么只调 XRSLAMGetVersion:它是**唯一**不需要 yaml 配置、不需要相机/IMU 数据、
// 不需要 XRSLAMCreate 就能调的 API。所以它把「FFI 通路通不通」与「VIO 跑不跑得起来」
// 彻底分开 —— 这条不通,后面所有集成工作都建立在流沙上。
//
// 它同时顺带验了四件我们今天专门做的事:
//   ① 符号真的被导出且没被 dead-strip(Podfile 的 -Wl,-u,_XRSLAMGetVersion)
//   ② 双调用惯用法(先传 NULL 查长度,再分配)在 Dart 侧真的成立
//   ③ 出参契约:非 NULL 时库无条件先清零
//   ④ 返回码常量与 C 头一致(契约测试已在 host 侧钉过,这里是真机复核)
//
// ⚠️ 通了**不代表** VIO 能跑。它只证明「库在进程里、符号可查、ABI 对得上」。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'xrslam_bindings.dart';
import 'xrslam_config.dart';
import 'xrslam_status.dart';

/// 一次 smoke 的结果。字段都是事实,不做解释 —— 解释留给读日志的人。
class XrslamSmokeResult {
  const XrslamSmokeResult({
    required this.symbolFound,
    required this.probeRc,
    required this.neededChars,
    required this.fetchRc,
    required this.version,
    required this.error,
    this.createRc,
    this.destroyed,
    this.configProvenance,
  });

  /// `DynamicLibrary.process().lookup` 有没有找到符号。
  /// false ⇒ 链接期被 dead-strip 了,或者 .a 根本没进链接图。
  final bool symbolFound;

  /// 第一次调用(out_buf=NULL,查长度)的返回码。
  final int probeRc;

  /// 库报的所需字符数(不含结尾 '\0')。
  final int neededChars;

  /// 第二次调用(真取)的返回码。
  final int fetchRc;

  /// 取到的版本串。上游当前是 "xrslam v0.5.0"。
  final String? version;

  /// 异常信息。symbolFound=false 时这里会有 lookup 的原始错误。
  final String? error;

  /// XRSLAMCreate 的返回码。⚠️ 上游遗留约定 **1=成功 / 0=失败**,
  /// 与其余 API 的 0=OK 正好相反 —— 判它必须用 xrslamCreateSucceeded。
  final int? createRc;

  /// XRSLAMDestroy 是否已调用(生命周期闭环)。
  final bool? destroyed;

  /// 配置各字段的来源。含 PLACEHOLDER 时,结果不得用于报绝对尺寸。
  final Map<String, String>? configProvenance;

  bool get ok =>
      symbolFound &&
      xrslamSucceeded(probeRc) &&
      xrslamSucceeded(fetchRc) &&
      version != null &&
      version!.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'symbolFound': symbolFound,
        'probeRc': probeRc,
        'probeRcName': xrslamStatusName(probeRc),
        'neededChars': neededChars,
        'fetchRc': fetchRc,
        'fetchRcName': xrslamStatusName(fetchRc),
        'version': version,
        'error': error,
        'createRc': createRc,
        'createOk': createRc == null ? null : xrslamCreateSucceeded(createRc!),
        'destroyed': destroyed,
        'configProvenance': configProvenance,
      };

  @override
  String toString() => ok
      ? 'XRSLAM FFI OK — version="$version" (needed=$neededChars chars)'
      : 'XRSLAM FFI FAIL — symbolFound=$symbolFound '
          'probe=${xrslamStatusName(probeRc)} fetch=${xrslamStatusName(fetchRc)} '
          'err=$error';
}

/// 跑一次最小验证。**不抛异常** —— 诊断代码自己崩掉是最没用的失败方式。
XrslamSmokeResult runXrslamSmoke() {
  // 静态链接进 Runner ⇒ 用 process() 而不是 open()。
  // open('libxrslam.dylib') 在这里必然失败:我们出的是 .a 不是 .dylib。
  late final XrslamBindings bindings;
  try {
    bindings = XrslamBindings(ffi.DynamicLibrary.process());
  } catch (e) {
    return XrslamSmokeResult(
      symbolFound: false,
      probeRc: xrslamErrInternal,
      neededChars: -1,
      fetchRc: xrslamErrInternal,
      version: null,
      error: 'DynamicLibrary.process() failed: $e',
    );
  }

  final ffi.Pointer<ffi.Int32> lenPtr = calloc<ffi.Int32>();
  ffi.Pointer<ffi.Char> buf = ffi.nullptr;
  try {
    // ── 第一段:out_buf=NULL,只查所需长度 ──
    // 这一段同时验了「出参在任何返回路径上都被写」:lenPtr 是 calloc 出来的 0,
    // 库若不写就还是 0,而版本串不可能是 0 长度。
    lenPtr.value = 0;
    final int probeRc = bindings.XRSLAMGetVersion(ffi.nullptr, lenPtr);
    final int needed = lenPtr.value;
    if (!xrslamSucceeded(probeRc) || needed <= 0) {
      return XrslamSmokeResult(
        symbolFound: true,
        probeRc: probeRc,
        neededChars: needed,
        fetchRc: xrslamErrInternal,
        version: null,
        error: needed <= 0
            ? '查长度返回 $needed —— 库没写出参,或版本串为空'
            : null,
      );
    }

    // ── 第二段:按报的长度分配并真取 ──
    // +1 给结尾 '\0'。契约里 io_len 的入值是**容量(含 '\0')**,
    // 出值是**写入字符数(不含 '\0')** —— 这两个口径不同,最容易写错的一处。
    buf = calloc<ffi.Char>(needed + 1);
    lenPtr.value = needed + 1;
    final int fetchRc = bindings.XRSLAMGetVersion(buf, lenPtr);
    final int written = lenPtr.value;
    final String? version = xrslamSucceeded(fetchRc) && written > 0
        ? buf.cast<Utf8>().toDartString(length: written)
        : null;

    return XrslamSmokeResult(
      symbolFound: true,
      probeRc: probeRc,
      neededChars: needed,
      fetchRc: fetchRc,
      version: version,
      error: version == null ? '取版本失败:written=$written' : null,
    );
  } catch (e) {
    // 符号查不到时 ffigen 的 lazy lookup 会在**第一次调用**抛,不是构造时。
    return XrslamSmokeResult(
      symbolFound: false,
      probeRc: xrslamErrInternal,
      neededChars: -1,
      fetchRc: xrslamErrInternal,
      version: null,
      error: '$e',
    );
  } finally {
    calloc.free(lenPtr);
    if (buf != ffi.nullptr) calloc.free(buf);
  }
}

/// 生命周期验证:XRSLAMCreate → XRSLAMDestroy 走一遍。
///
/// 比 [runXrslamSmoke] 深一层 —— 它真的加载配置、构造求解器、再销毁。
/// 通过 = 「YAML 解析器吃得下我们运行时生成的配置」+「构造/析构不崩」。
///
/// ⚠️ 仍然**不代表 VIO 能跑**:没喂过任何一帧图像或 IMU。
///
/// ⚠️ 用的是占位内参 —— 真实值要从 AVCameraCalibrationData 读。
///    结果里的 configProvenance 会如实标出哪些字段是 PLACEHOLDER。
XrslamSmokeResult runXrslamLifecycle({CameraIntrinsics? intrinsics}) {
  final XrslamSmokeResult base = runXrslamSmoke();
  if (!base.ok) return base;   // 通路都不通就别往下走

  // 没传就用一组**明确标记为占位**的值。1280x720 下 fx≈fy≈1000 是
  // iPhone 主摄的量级,但**这不是标定值** —— provenance 会如实说。
  final CameraIntrinsics k = intrinsics ??
      const CameraIntrinsics(
        fx: 1000.0, fy: 1000.0, cx: 640.0, cy: 360.0,
        resolutionWidth: 1280, resolutionHeight: 720,
        provenance: FieldProvenance.placeholder,
      );
  final XrslamConfigBuilder builder = XrslamConfigBuilder(intrinsics: k);

  final XrslamBindings bindings = XrslamBindings(ffi.DynamicLibrary.process());
  // 我们的构建打开了 XRSLAM_CONFIG_FROM_STRING ⇒ 这两个参数是 **YAML 正文**,
  // 不是文件路径。传路径进去会被当 YAML 解析然后失败。
  final ffi.Pointer<ffi.Char> slamCfg =
      builder.buildSlamConfigYaml().toNativeUtf8().cast<ffi.Char>();
  final ffi.Pointer<ffi.Char> devCfg =
      builder.buildDeviceConfigYaml().toNativeUtf8().cast<ffi.Char>();
  final ffi.Pointer<ffi.Char> license = ''.toNativeUtf8().cast<ffi.Char>();
  final ffi.Pointer<ffi.Char> product =
      'pocketworld'.toNativeUtf8().cast<ffi.Char>();
  final ffi.Pointer<ffi.Pointer<ffi.Void>> cfgOut =
      calloc<ffi.Pointer<ffi.Void>>();

  int? createRc;
  bool destroyed = false;
  String? err;
  try {
    createRc =
        bindings.XRSLAMCreate(slamCfg, devCfg, license, product, cfgOut);
    // ⚠️ 这里**必须**用 xrslamCreateSucceeded:上游是 1=成功/0=失败,
    //    用常规的 rc>=0 会把失败当成功。
    if (xrslamCreateSucceeded(createRc)) {
      bindings.XRSLAMDestroy();
      destroyed = true;
    } else {
      err = 'XRSLAMCreate 返回 $createRc(约定 1=成功);'
          'cfgOut=${cfgOut.value.address}';
    }
  } catch (e) {
    err = 'lifecycle threw: $e';
  } finally {
    calloc.free(slamCfg);
    calloc.free(devCfg);
    calloc.free(license);
    calloc.free(product);
    calloc.free(cfgOut);
  }

  return XrslamSmokeResult(
    symbolFound: base.symbolFound,
    probeRc: base.probeRc,
    neededChars: base.neededChars,
    fetchRc: base.fetchRc,
    version: base.version,
    error: err ?? base.error,
    createRc: createRc,
    destroyed: destroyed,
    configProvenance: builder.provenanceReport(),
  );
}
