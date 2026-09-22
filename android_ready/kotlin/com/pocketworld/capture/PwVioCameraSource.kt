package com.pocketworld.capture

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.util.Log
import android.util.Range
import android.util.Size

/**
 * camera2 相机源 —— Android 侧此前**完全不存在**的那一环。
 *
 * ══ 模板出处（不是自研）════════════════════════════════════════════════════
 * 会话搭建的骨架抄 Google 官方样例 **Camera2Basic**：
 *   https://github.com/android/camera-samples/tree/main/Camera2Basic
 *   （`Camera2BasicFragment` / `CameraFragment`：`CameraManager.openCamera` →
 *    `CameraDevice.StateCallback` → `createCaptureSession(targets, …)` →
 *    `CaptureRequest.Builder(TEMPLATE_PREVIEW).addTarget(reader.surface)` →
 *    `setRepeatingRequest(…, captureCallback, handler)`，以及
 *    `ImageReader.OnImageAvailableListener` 里 `acquireNextImage()` 的用法。）
 * 本文件对它的**四处改动**全部是 VIO 要求，每条都有出处：
 *
 *  (a) 目标格式固定 `ImageFormat.YUV_420_888`，只取 **Y 平面**。
 *      Y 平面就是 8 位灰度、`pixelStride` 规范恒为 1 ⇒ 直接是引擎要的
 *      `CV_8UC1`（`XRSLAMManager.cpp:143-145` @4beb1a9：`channel == 1` 时
 *      `cv::Mat(rows, cols, CV_8UC1, data, stride)`，**不做 cvtColor**）。
 *      样例用 JPEG，那是给存照片用的。
 *
 *  (b) 分辨率**下限 1920×1440**（产品要求）。样例按预览控件尺寸选，我们按
 *      硬下限选：优先精确 1920×1440，否则取**面积最小的 ≥1920×1440**，
 *      都没有就取最大的并把 `degraded` 报出去 —— 不静默降档。
 *
 *  (c) `CONTROL_AE_TARGET_FPS_RANGE` 取设备支持的**最高上界**（30/60），
 *      并在同上界的候选里优先**定帧**区间 `[x, x]`：可变区间会让曝光在暗处
 *      拉长到 1/15 s，而曝光时长直接进时间戳换算（`exposure/2`）且运动模糊
 *      直接打特征。
 *
 *  (d) `PwCameraProbe.applyVioTuning` 把 EIS / OIS / 畸变校正关掉。
 *      🔴 关掉畸变校正意味着**图像是带畸变的** ⇒ `device_config.yaml` 必须写
 *      `camera_distortion_flag: 1` + camera2 的 `LENS_DISTORTION` 系数。
 *      [describeSelection] 把这两样一起交出去，由 `PwDeviceCalibration`
 *      写进 yaml。
 *
 * ══ 帧与元数据的配对 ══════════════════════════════════════════════════════
 * `Image.getTimestamp()` 与 `CaptureResult.SENSOR_TIMESTAMP` 是**同一个值**
 * （camera2 文档口径），所以按它精确配对，不按到达顺序猜。结果与图像不保证
 * 同时到，配不上的帧退回上一帧的曝光/skew 并计数
 * （`PwXrslamFeed.timebase()` 的第 14 项），不丢帧也不伪造。
 *
 * ══ 🔴 本文件不开相机，也不申请权限 ═══════════════════════════════════════
 * `open()` 要求调用方已经拿到 `android.permission.CAMERA`。没有 Android 设备
 * 可验，这里的每个 camera2 符号都对照 Google 的公开参考核过（见
 * `android_ready/README.md` 的 *API provenance* 一节），但**第一次 Gradle
 * 构建才是真正的评审**。
 */
class PwVioCameraSource(
    private val context: Context,
    /** 三条流共享的**串行到达上下文**。必须是 `PwXrslamFeed.arrivalHandler`。 */
    private val arrivalHandler: Handler,
    private val feed: PwXrslamFeed,
) {

    companion object {
        private const val TAG = "PwVioCameraSource"

        /** 产品硬下限。永远不用 LiDAR，分辨率最低 1920×1440。 */
        const val MIN_WIDTH = 1920
        const val MIN_HEIGHT = 1440

        /** `ImageReader` 深度。比 `PwXrslamFeed` 的在途闸(2)多留两格：
         *  闸拒绝的那一帧我们要能**先 acquire 再 close**，才能算进自己的账。 */
        private const val READER_MAX_IMAGES = 4
    }

    /** 选型结果。全部是事实，没有判定。 */
    data class Selection(
        val cameraId: String,
        val width: Int,
        val height: Int,
        /** 达到了 1920×1440 下限吗。false ⇒ 这台机器交不出产品要求的分辨率。 */
        val meetsMinimum: Boolean,
        val fpsRange: IntArray?,
        val timestampSource: Int,
        /** `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME` ⇒ 与 `SensorEvent.timestamp` 同域。 */
        val timestampSourceIsRealtime: Boolean,
        /** `LENS_INTRINSIC_CALIBRATION` = [fx, fy, cx, cy, s]，optional key。 */
        val intrinsicCalibration: DoubleArray?,
        /** `LENS_DISTORTION`，optional key（API 28）。 */
        val distortion: DoubleArray?,
        val appliedTuning: Map<String, Boolean>,
    ) {
        override fun equals(other: Any?): Boolean = this === other
        override fun hashCode(): Int = System.identityHashCode(this)
    }

    private val manager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null

    var selection: Selection? = null
        private set

    /** acquire 失败次数（`IllegalStateException` / null）。相机侧的丢帧归因。 */
    var acquireFailures = 0L
        private set

    // ── 选型 ──────────────────────────────────────────────────────────────

    /** 后置相机 id。找不到后置就退回第一个，并把实际 facing 报在日志里。 */
    private fun pickBackCameraId(): String? {
        val ids = try {
            manager.cameraIdList
        } catch (e: CameraAccessException) {
            Log.e(TAG, "cameraIdList failed", e)
            return null
        }
        for (id in ids) {
            val c = manager.getCameraCharacteristics(id)
            if (c.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
            ) {
                return id
            }
        }
        return ids.firstOrNull()
    }

    /**
     * 分辨率选型。见类注释改动 (b)。
     * @return null ⇒ 这台机器一个 YUV_420_888 输出尺寸都没有（不可能，但不猜）。
     */
    internal fun pickSize(sizes: Array<Size>?): Size? {
        if (sizes == null || sizes.isEmpty()) return null
        sizes.firstOrNull { it.width == MIN_WIDTH && it.height == MIN_HEIGHT }?.let { return it }
        val atLeast = sizes.filter { it.width >= MIN_WIDTH && it.height >= MIN_HEIGHT }
        if (atLeast.isNotEmpty()) {
            return atLeast.minByOrNull { it.width.toLong() * it.height.toLong() }
        }
        return sizes.maxByOrNull { it.width.toLong() * it.height.toLong() }
    }

    /**
     * 帧率选型。见类注释改动 (c)：先按上界取最大，同上界里优先定帧区间。
     */
    internal fun pickFpsRange(ranges: Array<Range<Int>>?): Range<Int>? {
        if (ranges == null || ranges.isEmpty()) return null
        val maxUpper = ranges.maxOf { it.upper }
        val top = ranges.filter { it.upper == maxUpper }
        return top.firstOrNull { it.lower == it.upper } ?: top.first()
    }

    // ── 生命周期 ──────────────────────────────────────────────────────────

    /**
     * 打开相机并起 repeating request。
     *
     * 🔴 调用方必须已持有 `android.permission.CAMERA`；这里不申请、不判断。
     * @return 0 排队成功（真正的成败在 [onOpened]/[onError] 的回调里）；
     *   −1 无相机；−2 无 `StreamConfigurationMap`；−3 无可用尺寸；
     *   −4 `CameraAccessException`；−5 缺权限（`SecurityException`）。
     */
    fun open(): Int {
        val id = pickBackCameraId() ?: return -1
        val chars = manager.getCameraCharacteristics(id)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return -2
        val size = pickSize(map.getOutputSizes(ImageFormat.YUV_420_888)) ?: return -3

        val meets = size.width >= MIN_WIDTH && size.height >= MIN_HEIGHT
        if (!meets) {
            Log.e(
                TAG,
                "🔴 ${size.width}x${size.height} < 产品下限 ${MIN_WIDTH}x$MIN_HEIGHT " +
                    "—— 这台机器交不出要求的分辨率，结果不可用于产品对照",
            )
        }

        val fps = pickFpsRange(
            chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES),
        )
        val tsSource = chars.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
            ?: CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN

        val r = ImageReader.newInstance(
            size.width, size.height, ImageFormat.YUV_420_888, READER_MAX_IMAGES,
        )
        r.setOnImageAvailableListener(onImageAvailable, arrivalHandler)
        reader = r

        selection = Selection(
            cameraId = id,
            width = size.width,
            height = size.height,
            meetsMinimum = meets,
            fpsRange = fps?.let { intArrayOf(it.lower, it.upper) },
            timestampSource = tsSource,
            timestampSourceIsRealtime =
                tsSource == CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME,
            intrinsicCalibration =
                chars.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
                    ?.map { it.toDouble() }?.toDoubleArray(),
            distortion = readDistortion(chars),
            appliedTuning = emptyMap(),
        )

        return try {
            manager.openCamera(id, stateCallback, arrivalHandler)
            0
        } catch (e: CameraAccessException) {
            Log.e(TAG, "openCamera failed", e)
            -4
        } catch (e: SecurityException) {
            Log.e(TAG, "openCamera denied -- CAMERA permission is the caller's job", e)
            -5
        }
    }

    private fun readDistortion(c: CameraCharacteristics): DoubleArray? {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.P) return null
        return c.get(CameraCharacteristics.LENS_DISTORTION)
            ?.map { it.toDouble() }?.toDoubleArray()
    }

    fun close() {
        try { session?.close() } catch (_: Throwable) {}
        try { device?.close() } catch (_: Throwable) {}
        try { reader?.close() } catch (_: Throwable) {}
        session = null
        device = null
        reader = null
    }

    // ── camera2 回调 ──────────────────────────────────────────────────────

    private val stateCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(camera: CameraDevice) {
            device = camera
            startSession(camera)
        }

        override fun onDisconnected(camera: CameraDevice) {
            Log.w(TAG, "camera disconnected")
            close()
        }

        override fun onError(camera: CameraDevice, error: Int) {
            Log.e(TAG, "camera error $error")
            close()
        }
    }

    @Suppress("DEPRECATION")
    private fun startSession(camera: CameraDevice) {
        val surface = reader?.surface ?: return
        // minSdk 24 ⇒ 用这个重载。API 28 的 `SessionConfiguration` 更新，但它
        // 不改变本文件的任何行为，而多一条分支就多一处只能在设备上验的代码。
        camera.createCaptureSession(
            listOf(surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    startRepeating(camera, s, surface)
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    Log.e(TAG, "🔴 createCaptureSession failed")
                }
            },
            arrivalHandler,
        )
    }

    private fun startRepeating(
        camera: CameraDevice,
        s: CameraCaptureSession,
        surface: android.view.Surface,
    ) {
        val chars = manager.getCameraCharacteristics(camera.id)
        val b = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
        b.addTarget(surface)

        val applied = PwCameraProbe.applyVioTuning(chars, b)

        selection?.fpsRange?.let {
            b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(it[0], it[1]))
        }

        selection = selection?.copy(appliedTuning = applied)
        Log.i(
            TAG,
            "session up ${selection?.width}x${selection?.height} " +
                "fps=${selection?.fpsRange?.joinToString("-")} " +
                "tsSource=${selection?.timestampSource} tuning=$applied",
        )

        try {
            s.setRepeatingRequest(b.build(), captureCallback, arrivalHandler)
        } catch (e: CameraAccessException) {
            Log.e(TAG, "setRepeatingRequest failed", e)
        }
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            s: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
            val ts = result.get(CaptureResult.SENSOR_TIMESTAMP) ?: return
            feed.offerCaptureResult(
                PwXrslamFeed.FrameMetadata(
                    sensorTimestampNs = ts,
                    exposureTimeNs = result.get(CaptureResult.SENSOR_EXPOSURE_TIME),
                    rollingShutterSkewNs =
                        result.get(CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW),
                ),
            )
        }
    }

    /**
     * 🔴 用 `acquireNextImage()`，**不用 ImageReader 的 acquire-latest 那个重载**
     * （那个名字在本仓被契约测试禁掉，所以这里连写都不写）。它会**静默**丢掉
     * 除最新之外的全部帧 —— 丢帧的账就记在平台里，我们再也分不清「引擎吃不下」
     * 和「我们没来取」。这里每一帧都取出来，要么交给 [PwXrslamFeed] 的闸，
     * 要么被它计数丢弃。
     */
    private val onImageAvailable = ImageReader.OnImageAvailableListener { r ->
        val image: Image? = try {
            r.acquireNextImage()
        } catch (e: IllegalStateException) {
            acquireFailures += 1
            Log.w(TAG, "acquireNextImage: reader full", e)
            null
        }
        if (image == null) {
            acquireFailures += 1
            return@OnImageAvailableListener
        }
        val y = image.planes[0]
        feed.offerFrame(
            luma = y.buffer,
            rowStride = y.rowStride,
            pixelStride = y.pixelStride,
            sensorTimestampNs = image.timestamp,
            release = { image.close() },
        )
    }

    /** 选型事实，交给 `PwDeviceCalibration.buildDeviceConfigYaml` 用。 */
    fun describeSelection(): Map<String, Any?> {
        val s = selection ?: return emptyMap()
        return mapOf(
            "cameraId" to s.cameraId,
            "width" to s.width,
            "height" to s.height,
            "meetsMinimum" to s.meetsMinimum,
            "fpsRange" to s.fpsRange?.toList(),
            "timestampSource" to s.timestampSource,
            "timestampSourceIsRealtime" to s.timestampSourceIsRealtime,
            "intrinsicCalibration" to s.intrinsicCalibration?.toList(),
            "distortion" to s.distortion?.toList(),
            "appliedTuning" to s.appliedTuning,
            "acquireFailures" to acquireFailures,
        )
    }
}
