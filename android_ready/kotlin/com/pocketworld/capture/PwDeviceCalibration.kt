package com.pocketworld.capture

import android.os.Build
import android.util.Log

/**
 * 逐机型标定表 + 三态 provenance —— 结构照抄 iOS 的
 * `lib/vio/ffi/xrslam_config.dart:215-285`（`CameraImuExtrinsic.forIosMachine`）。
 *
 * ══ 🔴 表是空的，而且必须空 ══════════════════════════════════════════════
 * iOS 那 18 份 `p_bc`/`q_bc` 不是我们测的，是上游 `xrslam-ios/visualizer/configs/`
 * 里逐机型标定过的 yaml。**Android 上游一份都没有**（agent4 报告 §6(b)：
 * `xrslam-ios/…/configs/` 两棵树各 18 个 iPhone yaml，Android yaml **0 个**）。
 *
 * 所以这里**一个数字都不许编**。表留空、provenance 一律 `PLACEHOLDER`、
 * create 时打醒目日志。空表不是遗漏，它是「Android 逐机型标定这件事还没做」
 * 这个事实在代码里的唯一诚实表示；填一组看起来合理的数字会把这个缺口抹掉。
 *
 * ══ 为什么 q_bc 也不能抄 iOS ═════════════════════════════════════════════
 * iOS 的 `kIosCameraImuQbc` 对 18 款 iPhone 全相同（180° 翻转），因为 Apple 的
 * 相机/IMU 轴系约定是全系一致的。Android 没有这个保证：camera2 有
 * `LENS_POSE_ROTATION`/`LENS_POSE_TRANSLATION`（API 23，**optional key**），
 * 它给的才是这台机器自己的答案。`PwCameraProbe.characteristics()` 已经把两项
 * 读出来了（`poseRotation`/`poseTranslation`），[fromCameraPose] 在它们存在时
 * 用它们并标 `DEVICE_API`。
 *
 * 🔴 但 `LENS_POSE_*` 的坐标系与 XRSLAM 的 `q_bc`/`p_bc` 是否同一约定
 * （方向、参考系 `LENS_POSE_REFERENCE`、平移是 c→b 还是 b→c）**没有在这台机器
 * 上核过**，本机无 Android 设备。所以 [fromCameraPose] 默认**不启用**：
 * 调用方必须显式传 `trustCameraPose = true`，而那需要先在真机上做一次核对。
 * 未核对之前它就是 [placeholder]。
 */
object PwDeviceCalibration {

    private const val TAG = "PwDeviceCalibration"

    /** 三态 + measured，与 Dart 的 `FieldProvenance` 逐项对齐。 */
    enum class Provenance(val label: String) {
        /** 从系统 API 读到的（camera2 `LENS_POSE_*`）。 */
        DEVICE_API("device-api"),

        /** 我们自己在这台机上测出来的。 */
        MEASURED("measured"),

        /** 行业/上游共享默认值，有依据但不是这台机的。 */
        SHARED_DEFAULT("shared-default"),

        /** 占位，**没有依据**。任何用到它的结果都不能报绝对精度。 */
        PLACEHOLDER("PLACEHOLDER"),
    }

    /** 相机-IMU 外参。`qbc` 是 [x,y,z,w]；`pbc` 单位米。 */
    data class Extrinsic(
        val qbc: DoubleArray,
        val pbc: DoubleArray,
        val provenance: Provenance,
    ) {
        override fun equals(other: Any?): Boolean =
            other is Extrinsic &&
                qbc.contentEquals(other.qbc) &&
                pbc.contentEquals(other.pbc) &&
                provenance == other.provenance

        override fun hashCode(): Int =
            (qbc.contentHashCode() * 31 + pbc.contentHashCode()) * 31 +
                provenance.hashCode()
    }

    /**
     * 机型键。用 `Build.MANUFACTURER/Build.DEVICE/Build.MODEL` 三段拼，
     * 对应 iOS 的 `hw.machine`。
     *
     * 选 `Build.DEVICE` 而不是 `Build.MODEL` 作主键的依据是 Google 自己：
     * ARCore 的 device profile 就是按 `ro.product.device` 索引的
     * （`Build.DEVICE` == `ro.product.device`），而 `MODEL` 是营销名，
     * 同一块硬件可以有多个。三段都记下来是为了遥测能看出漏表的是哪台机。
     */
    fun deviceKey(): String =
        "${Build.MANUFACTURER}/${Build.DEVICE}/${Build.MODEL}".lowercase()

    /**
     * 逐机型 `p_bc`/`q_bc` 表。
     *
     * 🔴 **故意为空。** 填进来的每一项都必须能指到一份具体的标定产物
     * （上游 yaml、我们自己跑的 iKalibr/Kalibr 输出），并在这里写出处。
     * 没有出处的数字不许进这张表。
     */
    private val TABLE: Map<String, Extrinsic> = emptyMap()

    /**
     * 明确无依据的占位。单位四元数 + 零平移。
     *
     * 🔴 iOS 那边的同名常量带着一条实测教训（`xrslam_config.dart:238-247`）：
     * 单位四元数喂 5731 帧一个位姿都出不来（slamState 恒 0），因为 iPhone 的
     * 真值是 180° 翻转。Android 的真值未知，**这个占位大概率也是错的** ——
     * 它存在的唯一目的是让「没查到表就跑」这件事在 provenance 里显形，
     * 而不是提供一个能用的默认。
     */
    val placeholder = Extrinsic(
        qbc = doubleArrayOf(0.0, 0.0, 0.0, 1.0),
        pbc = doubleArrayOf(0.0, 0.0, 0.0),
        provenance = Provenance.PLACEHOLDER,
    )

    /**
     * 查表。查不到返回 [placeholder]（provenance = PLACEHOLDER），
     * 而不是 iOS 那样的「分量中位数 + SHARED_DEFAULT」—— 因为我们连一个
     * Android 实测值都没有，中位数没有样本可取。
     */
    fun forThisDevice(): Extrinsic = TABLE[deviceKey()] ?: placeholder

    /**
     * camera2 自报的相机位姿。**默认不启用**，见类注释。
     *
     * @param poseRotation `LENS_POSE_ROTATION`，四元数 [x,y,z,w]（camera2 文档口径）
     * @param poseTranslation `LENS_POSE_TRANSLATION`，米
     * @param trustCameraPose 只有在真机上核对过 camera2 与 XRSLAM 的
     *   `q_bc`/`p_bc` 约定一致之后才允许传 true。
     */
    fun fromCameraPose(
        poseRotation: DoubleArray?,
        poseTranslation: DoubleArray?,
        trustCameraPose: Boolean,
    ): Extrinsic {
        if (!trustCameraPose) return forThisDevice()
        if (poseRotation == null || poseRotation.size < 4) return forThisDevice()
        if (poseTranslation == null || poseTranslation.size < 3) return forThisDevice()
        return Extrinsic(
            qbc = doubleArrayOf(
                poseRotation[0], poseRotation[1], poseRotation[2], poseRotation[3],
            ),
            pbc = doubleArrayOf(
                poseTranslation[0], poseTranslation[1], poseTranslation[2],
            ),
            provenance = Provenance.DEVICE_API,
        )
    }

    /**
     * 每机常量 `c`（秒）：曝光中点换算里**不能从 camera2 元数据算出来**的那部分
     * （管线固定延迟）。能算的那部分 —— `exposure/2 + rolling_shutter_skew/2` ——
     * 由 [PwXrslamFeed] 在推之前加掉，不走这里。
     *
     * 🔴 Android 的 `c` 与 iOS 一样是**一场定**的每机常量，而我们一台 Android
     * 机都没标过 ⇒ 表空、返回 0.0、provenance = PLACEHOLDER。
     * 0.0 不是「测出来是 0」，是「没测」。
     */
    private val CAMERA_TIME_OFFSET_SECONDS: Map<String, Double> = emptyMap()

    fun cameraTimeOffsetSeconds(): Double =
        CAMERA_TIME_OFFSET_SECONDS[deviceKey()] ?: 0.0

    fun cameraTimeOffsetProvenance(): Provenance =
        if (CAMERA_TIME_OFFSET_SECONDS.containsKey(deviceKey())) {
            Provenance.MEASURED
        } else {
            Provenance.PLACEHOLDER
        }

    /**
     * 🔴 醒目日志。由 [PwXrslamFeed.create] 在建会话时调一次。
     * @return 这次会话里所有 placeholder 字段的名字；空 ⇒ 全部有依据。
     */
    fun logProvenance(extrinsic: Extrinsic, intrinsicsProvenance: Provenance): List<String> {
        val placeholders = ArrayList<String>()
        if (extrinsic.provenance == Provenance.PLACEHOLDER) placeholders.add("cam0.extrinsic")
        if (cameraTimeOffsetProvenance() == Provenance.PLACEHOLDER) {
            placeholders.add("cam0.time_offset")
        }
        if (intrinsicsProvenance == Provenance.PLACEHOLDER) placeholders.add("cam0.intrinsics")

        Log.i(
            TAG,
            "device=${deviceKey()} extrinsic=${extrinsic.provenance.label} " +
                "time_offset=${cameraTimeOffsetSeconds()}s" +
                "(${cameraTimeOffsetProvenance().label}) " +
                "intrinsics=${intrinsicsProvenance.label}",
        )
        if (placeholders.isNotEmpty()) {
            Log.w(
                TAG,
                "🔴 PLACEHOLDER calibration in use: ${placeholders.joinToString(", ")} " +
                    "-- this run MUST NOT report absolute scale. " +
                    "Android per-device p_bc/q_bc/c have never been calibrated; " +
                    "the table in PwDeviceCalibration is deliberately empty.",
            )
        }
        return placeholders
    }

    /**
     * 生成 `device_config.yaml`。逐字段对齐 iOS 的
     * `XrslamConfigBuilder.buildDeviceConfigYaml()`
     * （`lib/vio/ffi/xrslam_config.dart:378-421`），包括那几条注释所记录的坑：
     *  · `noise` 必须是 2×2 矩阵，标量会被 `assign_matrix` 判类型错 ⇒
     *    `XRSLAMCreate` 直接返回 0。
     *  · `cov_*` 四个协方差逐字沿用上游 18 份 iPhone yaml 的值
     *    （`ImuNoise.sharedMems`），标 shared-default。这是**MEMS IMU 的通用
     *    量级**不是这台 Android 机的实测，provenance 如实标注。
     *  · `camera_distortion_flag: 0` —— 前提是 `DISTORTION_CORRECTION_MODE`
     *    被 `PwCameraProbe.applyVioTuning` 关掉了**并且**没有畸变系数被喂进来。
     *    关掉畸变校正意味着**图像是带畸变的**，所以这里必须把 camera2 的
     *    `LENS_DISTORTION` 传进来；传不到就只能标 degraded。见 [distortion]。
     */
    fun buildDeviceConfigYaml(
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double,
        width: Int,
        height: Int,
        intrinsicsProvenance: Provenance,
        extrinsic: Extrinsic,
        /** camera2 `LENS_DISTORTION` 的前 4 项 [k1,k2,p1,p2]；null ⇒ 写 0 并标 degraded。 */
        distortion: DoubleArray?,
        pixelNoiseVariance: Double = 0.5,
    ): String {
        fun m3(v: Double) =
            "$v, 0.0, 0.0,\n          0.0, $v, 0.0,\n          0.0, 0.0, $v"

        // 上游 4beb1a9 的 18 份 iPhone yaml 对这四个协方差逐字相同。
        val covG = 2.8791302399999997e-08
        val covA = 4.0e-6
        val covBg = 3.7608844899999997e-10
        val covBa = 9.0e-6

        val d = if (distortion != null && distortion.size >= 4) distortion
        else doubleArrayOf(0.0, 0.0, 0.0, 0.0)
        val hasDistortion = distortion != null && distortion.size >= 4

        return """
%YAML:1.0
# GENERATED at runtime by PwDeviceCalibration (Android).
# 结构逐字段对齐 iOS 的 XrslamConfigBuilder.buildDeviceConfigYaml()。
# device: ${deviceKey()}
imu:
  extrinsic:
    q_bi: [ 0.0, 0.0, 0.0, 1.0 ]   # 单位四元数:IMU 即 body 系
    p_bi: [ 0.0, 0.0, 0.0 ]
  noise:
    # 来源:${Provenance.SHARED_DEFAULT.label} (上游 4beb1a9 的 18 份 iPhone yaml 逐字相同)
    cov_g: [
          ${m3(covG)}]
    cov_a: [
          ${m3(covA)}]
    cov_bg: [
          ${m3(covBg)}]
    cov_ba: [
          ${m3(covBa)}]
cam0:
  # 来源:${intrinsicsProvenance.label}
  intrinsics: [ $fx, $fy, $cx, $cy ]
  resolution: [ $width, $height ]
  # DISTORTION_CORRECTION_MODE 被关掉 ⇒ 图像**带畸变** ⇒ flag 必须是 1，
  # 且系数必须来自 camera2 LENS_DISTORTION。读不到就退回 0/0 并在日志里标 degraded。
  camera_distortion_flag: ${if (hasDistortion) 1 else 0}
  distortion: [ ${d[0]}, ${d[1]}, ${d[2]}, ${d[3]} ]
  # 2×2 关键点噪声协方差 [pixel²] —— 必须是矩阵，标量会被判类型错
  noise: [
    $pixelNoiseVariance, 0.0,
    0.0, $pixelNoiseVariance]
  # 来源:${cameraTimeOffsetProvenance().label}
  # 🔴 exposure/2 + skew/2 由 PwXrslamFeed 在推之前加掉，不走这个键；
  #    这里只剩每机常量 c，而 Android 一台都没标过 ⇒ 0.0 = 没测，不是测出来 0。
  time_offset: ${cameraTimeOffsetSeconds()}
  extrinsic:
    # 来源:${extrinsic.provenance.label}
    # ⚠️ PLACEHOLDER 意味着这不是标定值。Android 逐机型标定 yaml 目前 0 份。
    q_bc: [ ${extrinsic.qbc.joinToString(", ")} ]
    p_bc: [ ${extrinsic.pbc.joinToString(", ")} ]
""".trimStart()
    }
}
