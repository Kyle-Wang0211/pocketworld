// PwVioCapability.kt — Blocker 04 的 Android 侧(ready-to-drop)。
//
// ⚠️ 放置位置:这个文件**暂时**放在 lib/vio/capability/android/ 里,只是因为
//    /Users/kaidongwang/Developer/pocketworld 目前**没有 android/ 目录**
//    (Android 应用根本不存在)。等 Android 壳建起来后原样搬到
//        android/app/src/main/kotlin/com/pocketworld/vio/PwVioCapability.kt
//    并改掉 package 行。除 package 行外不需要任何改动。
//
// 🔴 **本文件从未被编译过。** 这台机器上没有 Android SDK
//    (~/Library/Android 不存在,找不到 android.jar),没有设备,没有 Gradle 工程。
//    下面每一个 API 名与它的可得条件都是从 AOSP 源码逐条核对的(见每处引文),
//    但"名字对"不等于"编得过"。第一次 assembleDebug 之前它一律按未验证对待。
//
// ─────────────────────────────────────────────────────────────────────────
// 与 iOS 侧的**结构性差异**(这正是不能用一套逐机型 yaml 的原因):
//
//                      iOS                          Android
//   EIS 可关?          可(preferredVideo-          可(CONTROL_VIDEO_STABILIZATION_
//                      StabilizationMode=.off)      MODE=OFF;"OFF will always be listed",
//                                                   该 characteristic"available on all devices")
//   OIS 可关?          🔴 **不可**。整个 SDK 里     可(LENS_OPTICAL_STABILIZATION_MODE
//                      没有任何公开 OIS 符号        =OFF),但受 LENS_INFO_AVAILABLE_
//                      (已用 swiftc 负向对照证明)  OPTICAL_STABILIZATION 约束,且是 Optional
//   逐帧内参?          有(CMSampleBuffer           **无**。Android 的内参是静态
//                      attachment)                  characteristic,不随帧下发
//   静态内参表?        无                           有(LENS_INTRINSIC_CALIBRATION),
//                                                   但 Optional,可能为 null
//   卷帘读出时间?      **无对应 API**               有(SENSOR_ROLLING_SHUTTER_SKEW),
//                                                   Optional / LIMITED 级以上
//   相机-陀螺外参?     无                           有(LENS_POSE_TRANSLATION/ROTATION),
//                                                   Optional,且见下面的 UNDEFINED 陷阱
//
// 两端能拿到的东西**完全不同**,所以判定必须建在"这次会话实际拿到了什么"上,
// 而不是建在机型表上。判定逻辑统一在 Dart 侧
// (lib/vio/capability/capability_probe.dart),本文件只负责如实上报。
//
// ─────────────────────────────────────────────────────────────────────────
// 🔴 最容易踩的一个坑:**非 null 不等于有意义。**
// AOSP 对 LENS_POSE_REFERENCE == UNDEFINED 的定义:
//   poseTranslation: "this position cannot be accurately represented by the camera
//                     device, and will be represented as (0, 0, 0)"
//   poseRotation:    "the quaternion rotation cannot be accurately represented ...
//                     and will be represented by default values matching its default facing"
// ⇒ UNDEFINED 时这两个 key **照样返回非 null 的数组**,但里面是编造的默认值。
//   直接拿去当 p_bc 用,会得到一个"看起来标定过"的错外参 —— 比缺失更危险。
//   本文件因此只在 poseReference ∈ {PRIMARY_CAMERA, GYROSCOPE} 时才上报外参。
//   (GYROSCOPE 是我们真正想要的那档:原点就是陀螺仪中心。)

package com.pocketworld.vio

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.os.Build

/** 与 Dart 侧 capability_evidence.dart 的 enum name 一一对应。 */
object PwVioWire {
    const val STAB_OFF = "off"
    const val STAB_ON = "on"
    const val STAB_UNKNOWN = "unknown"
    const val STAB_ABSENT = "absent"

    const val SRC_NONE = "none"
    const val SRC_FOV = "fieldOfViewFallback"
    const val SRC_STATIC = "staticCharacteristics"
    const val SRC_PLATFORM = "platformTracker"
    const val SRC_PER_FRAME = "perFrameAttachment"

    const val TB_UNIFIED = "unified"
    const val TB_OFFSET_MEASURED = "offsetMeasured"
    const val TB_UNRELATED = "unrelatedUnmeasured"
}

object PwVioCapability {

    // ─────────────────────────────────────────────────────────────────────
    // 时间基
    // ─────────────────────────────────────────────────────────────────────
    //
    // AOSP 对 SENSOR_INFO_TIMESTAMP_SOURCE 的说明:「This key is available on all
    // devices.」 —— 这是本文件里**唯一**一个保证存在的 key,其余全是 Optional。
    //   REALTIME → CaptureResult.SENSOR_TIMESTAMP 与 SensorEvent.timestamp 同为
    //              BOOTTIME ⇒ 直接可比 ⇒ unified。
    //   UNKNOWN  → 相机戳落在另一个单调基(实践中是 CLOCK_MONOTONIC),必须先测出
    //              BOOTTIME−MONOTONIC 偏移才能融合。偏移测量已由
    //              android_ready/dart/pw_android_capture/lib/src/clock_offset.dart
    //              实现(Cristian 最小往返法),这里只负责报告要不要用它。
    /**
     * @param measuredOffsetUncertaintyNs ClockOffset 测出来的**硬误差界**;
     *        没测出来传 null —— 传 0 会让 Dart 侧以为时间是完美对齐的。
     */
    @JvmStatic
    fun timebaseWire(
        characteristics: CameraCharacteristics,
        measuredOffsetUncertaintyNs: Long?
    ): Map<String, Any?> {
        val source = characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
        if (source == CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME) {
            return mapOf(
                "relation" to PwVioWire.TB_UNIFIED,
                "offsetUncertaintyNs" to 0L
            )
        }
        // UNKNOWN(或 null,极老设备)。没测出偏移就如实说不可用。
        return if (measuredOffsetUncertaintyNs != null) {
            mapOf(
                "relation" to PwVioWire.TB_OFFSET_MEASURED,
                "offsetUncertaintyNs" to measuredOffsetUncertaintyNs
            )
        } else {
            mapOf(
                "relation" to PwVioWire.TB_UNRELATED,
                "offsetUncertaintyNs" to null
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 内参(第一层:静态标定表)
    // ─────────────────────────────────────────────────────────────────────
    //
    // AOSP:LENS_INTRINSIC_CALIBRATION = [f_x, f_y, c_x, c_y, s],
    // 「Units: Pixels in the android.sensor.info.preCorrectionActiveArraySize
    //  coordinate system.」 + 「Optional - The value for this key may be null on
    //  some devices.」
    //
    // 🔴 参考分辨率必须用 **preCorrectionActiveArraySize**,不是 activeArraySize,
    //    也不是输出流尺寸。三者在多数机型上都不一样。拿错了,内参数值本身没错,
    //    但配错了参考系 ⇒ 主点偏移几十像素而且完全静默。Dart 侧的
    //    IntrinsicsFacts.remap 负责把它搬到实际出图口径,前提是这里带对参考系。
    @JvmStatic
    fun intrinsicsWire(characteristics: CameraCharacteristics): Map<String, Any?> {
        val k = characteristics.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
        val pre = characteristics.get(
            CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE
        )
        if (k == null || k.size < 5 || pre == null) {
            return mapOf(
                "source" to PwVioWire.SRC_NONE,
                "fx" to 0.0, "fy" to 0.0, "cx" to 0.0, "cy" to 0.0, "skew" to 0.0,
                "referenceWidth" to 0, "referenceHeight" to 0
            )
        }
        return mapOf(
            "source" to PwVioWire.SRC_STATIC,
            "fx" to k[0].toDouble(),
            "fy" to k[1].toDouble(),
            "cx" to k[2].toDouble(),
            "cy" to k[3].toDouble(),
            "skew" to k[4].toDouble(),
            "referenceWidth" to pre.width(),
            "referenceHeight" to pre.height()
        )
    }

    /**
     * 畸变系数。AOSP:LENS_DISTORTION = [kappa_1..kappa_5],Brown-Conrady,
     * 「Replaces the deprecated android.lens.radialDistortion field, which was
     *  inconsistently defined.」⇒ **永远不要读 LENS_RADIAL_DISTORTION**,
     * 它的定义与这个不一致,混用会得到错的去畸变。
     */
    @JvmStatic
    fun distortionWire(characteristics: CameraCharacteristics): Map<String, Any?> {
        val d = characteristics.get(CameraCharacteristics.LENS_DISTORTION)
        if (d == null || d.size < 5) return mapOf("available" to false)
        return mapOf(
            "available" to true,
            "model" to "brown_conrady",
            "k" to listOf(
                d[0].toDouble(), d[1].toDouble(), d[2].toDouble(),
                d[3].toDouble(), d[4].toDouble()
            )
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // 相机 ↔ 陀螺 外参(xrapi 里 p_bc 差 12mm 的那一项)
    // ─────────────────────────────────────────────────────────────────────
    //
    // 见文件头的 UNDEFINED 陷阱:只有 poseReference ∈ {PRIMARY_CAMERA, GYROSCOPE}
    // 时数值才是真的。GYROSCOPE 是我们要的那档。
    @JvmStatic
    fun extrinsicsWire(characteristics: CameraCharacteristics): Map<String, Any?> {
        val ref = characteristics.get(CameraCharacteristics.LENS_POSE_REFERENCE)
        val usable = ref == CameraCharacteristics.LENS_POSE_REFERENCE_GYROSCOPE ||
                ref == CameraCharacteristics.LENS_POSE_REFERENCE_PRIMARY_CAMERA
        if (!usable) {
            return mapOf(
                "available" to false,
                "reason" to "LENS_POSE_REFERENCE=$ref; AOSP states the pose values are " +
                        "filled with defaults when it is UNDEFINED, so a non-null array " +
                        "here would be fabricated, not calibrated."
            )
        }
        val t = characteristics.get(CameraCharacteristics.LENS_POSE_TRANSLATION)
        val r = characteristics.get(CameraCharacteristics.LENS_POSE_ROTATION)
        if (t == null || t.size < 3 || r == null || r.size < 4) {
            return mapOf("available" to false, "reason" to "pose keys null (Optional)")
        }
        return mapOf(
            "available" to true,
            // GYROSCOPE 时原点就是陀螺仪中心 —— 这正是 VIO 需要的 p_bc 参考点。
            "referenceIsGyroscope" to
                    (ref == CameraCharacteristics.LENS_POSE_REFERENCE_GYROSCOPE),
            // 单位:米。AOSP 提醒「for many computer vision applications, the position
            // needs to be negated to convert it to a translation from the camera to
            // the origin」—— 取负在消费侧做,这里保持 AOSP 原始约定不动。
            "translationMeters" to listOf(t[0].toDouble(), t[1].toDouble(), t[2].toDouble()),
            // 四元数系数顺序是 (x, y, z, w)。
            "rotationXyzw" to listOf(
                r[0].toDouble(), r[1].toDouble(), r[2].toDouble(), r[3].toDouble()
            )
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // 防抖:请求 + 读回
    // ─────────────────────────────────────────────────────────────────────

    /**
     * 在 CaptureRequest.Builder 上显式关掉两路防抖。
     *
     * AOSP 明确警告了两条:
     *   1. 「If a camera device supports both this mode and OIS ..., turning both modes
     *       on may produce undesirable interaction」
     *   2. 「If video stabilization is set to "PREVIEW_STABILIZATION",
     *       android.lens.opticalStabilizationMode is **overridden**」
     *      ⇒ 只要 EIS 不是 OFF,我们对 OIS 的设置就可能被无视。所以必须先把
     *        EIS 打到 OFF,而且**两路都要在 CaptureResult 里读回确认**。
     *
     * 另:AOSP 建议把它当 session parameter 提前给
     * (「strongly recommended to call SessionConfiguration#setSessionParameters with
     *   the desired video stabilization mode before creating the capture session」),
     * 否则首帧前会有一次重配置。调用方应当同时在 SessionConfiguration 里设一遍。
     */
    @JvmStatic
    fun requestStabilizationOff(
        builder: CaptureRequest.Builder,
        characteristics: CameraCharacteristics
    ) {
        // EIS:CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES「available on all devices」
        // 且「OFF will always be listed」⇒ 无条件可关。
        builder.set(
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF
        )
        // OIS:必须先确认 OFF 在可用列表里。列表本身是 Optional。
        val oisModes =
            characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
        if (oisModes != null &&
            oisModes.contains(CameraCharacteristics.LENS_OPTICAL_STABILIZATION_MODE_OFF)
        ) {
            builder.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF
            )
        }
    }

    /**
     * 从 **CaptureResult** 读回实际生效的状态。
     * 只看我们请求了什么是没有意义的 —— 请求只是请求。
     */
    @JvmStatic
    fun stabilizationWire(
        characteristics: CameraCharacteristics,
        result: TotalCaptureResult
    ): Map<String, Any?> {
        val availableEis =
            characteristics.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
        val oisModes =
            characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)

        val eisActual = result.get(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE)
        val oisActual = result.get(CaptureResult.LENS_OPTICAL_STABILIZATION_MODE)

        val eisState = when {
            eisActual == null -> PwVioWire.STAB_UNKNOWN
            eisActual == CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF -> PwVioWire.STAB_OFF
            else -> PwVioWire.STAB_ON
        }
        // OIS 硬件不存在时,AOSP 保证列表「will contain only OFF」⇒ 记 absent 而非 off,
        // 这样 Dart 侧能区分"没有这东西"和"关掉了"。
        val oisHardwareAbsent = oisModes != null && oisModes.size == 1 &&
                oisModes[0] == CameraCharacteristics.LENS_OPTICAL_STABILIZATION_MODE_OFF
        val oisState = when {
            oisHardwareAbsent -> PwVioWire.STAB_ABSENT
            oisActual == null -> PwVioWire.STAB_UNKNOWN
            oisActual == CaptureResult.LENS_OPTICAL_STABILIZATION_MODE_OFF -> PwVioWire.STAB_OFF
            else -> PwVioWire.STAB_ON
        }

        return mapOf(
            "electronic" to eisState,
            "optical" to oisState,
            "electronicControllable" to (availableEis != null && availableEis.isNotEmpty()),
            "opticalControllable" to (
                    oisModes != null &&
                            oisModes.contains(
                                CameraCharacteristics.LENS_OPTICAL_STABILIZATION_MODE_OFF
                            ) && !oisHardwareAbsent
                    )
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // 卷帘读出
    // ─────────────────────────────────────────────────────────────────────
    //
    // AOSP:「Optional」,「Limited capability - Present on all camera devices that
    // report being at least HARDWARE_LEVEL_LIMITED」。
    // 而且必须按实际读出的行数缩放:「if your output covers N rows of the active array
    // of height H, scale this value by N/H」。不缩放的话,在 binning/crop 模式下
    // 报出来的是**整阵列**的读出时间,会显著偏大。
    @JvmStatic
    fun rollingShutterWire(
        characteristics: CameraCharacteristics,
        result: TotalCaptureResult,
        outputRowsCoveringActiveArray: Int? = null
    ): Map<String, Any?> {
        val skew = result.get(CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW)
            ?: return mapOf("readoutNs" to null)
        val active = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val h = active?.height() ?: 0
        val n = outputRowsCoveringActiveArray ?: h
        val scaled = if (h > 0 && n in 1..h) skew * n / h else skew
        return mapOf("readoutNs" to scaled)
    }

    // ─────────────────────────────────────────────────────────────────────
    // 硬件等级(用来解释为什么某些 key 是 null,而不是当判据)
    // ─────────────────────────────────────────────────────────────────────
    @JvmStatic
    fun hardwareLevelName(characteristics: CameraCharacteristics): String {
        return when (characteristics.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
            else -> "UNKNOWN"
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // IMU:只搬运,不判定
    // ─────────────────────────────────────────────────────────────────────
    //
    // 采样率/抖动/成簇的判定在 Dart 侧的 ImuTimingProbe(Otsu),两端共用一份实现
    // 与一套单测。Kotlin 侧只负责把 (SensorEvent.timestamp, elapsedRealtimeNanos())
    // 二元组原样交上去 —— 绝不抽稀、绝不重排。
    //
    // ⚠️ registerListener 的 samplingPeriodUs 只是**建议**;Android 12(API 31)起
    //    所有 sensor 被硬压到 200Hz,除非应用持有 HIGH_SAMPLING_RATE_SENSORS。
    //    没有任何 API 返回达成率 —— 这正是必须实测的原因。
    //    maxReportLatencyUs 必须传 0(要求不批),但那同样只是要求,仍需实测确认。
    @JvmStatic
    fun highSamplingRatePermissionRelevant(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    @JvmStatic
    fun imuWire(sampleTsNs: LongArray, deliveryTsNs: LongArray): Map<String, Any?> = mapOf(
        "available" to (sampleTsNs.isNotEmpty()),
        "sampleTsNs" to sampleTsNs.toList(),
        "deliveryTsNs" to deliveryTsNs.toList()
    )
}
