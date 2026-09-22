package com.pocketworld.capture

import android.hardware.Sensor
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import java.nio.ByteBuffer

/**
 * PwXrslamFeed —— 把活体传感器喂给引擎的 **Android** 通路。
 *
 * ══ 这是 `ios/Runner/PwXrslamLive.swift` 的逐结构移植，不是新设计 ══════════
 * 对照表（左 iOS / 右本文件）：
 *
 * | 性质 | iOS (`PwXrslamLive.swift`) | 本文件 |
 * |---|---|---|
 * | 三条流共享一个**串行到达上下文** | `PwCameraSlot` 的 `queue`，IMU 用 `OperationQueue.underlyingQueue` 绑上去 | [arrivalHandler]（一条 `HandlerThread`）；`ImageReader.setOnImageAvailableListener` 与 `PwImuSource.start(externalHandler=)` 都挂它 |
 * | 算法只在**另一条串行 worker** 上跑 | `workQueue`（`DispatchQueue`，串行） | [workHandler]（另一条 `HandlerThread`） |
 * | 回调只做**有界入队**，绝不等算法 | `onCameraFrame` / `enqueueImu` | [offerFrame] / [enqueueImu] |
 * | 在途帧上限 2 | `maxPendingFrames = 2` | [MAX_PENDING_FRAMES] |
 * | 在途 IMU 上限 400 | `maxPendingImu = 400` | [MAX_PENDING_IMU] |
 * | 陀螺与加速度**分开推、各带自己的时间戳、先陀螺后加速度** | `onGyro` / `onAccel` 各自 push | [onImuSample]，注册顺序由 `PwImuSource.start()` 的 `wanted` 列表保证（陀螺在前） |
 * | push→RunOneFrame→GetResult 一次原子调用 | `PWXrslamTransportPushCameraAndRunRaw` | 同一个 C 入口，经 `PwXrslamTransport.pushCameraAndRunRaw` |
 * | 推完当帧读 C 账本做时基自证 | `runOneFrame` 里读 `PWXrslamTimestampTrace` | [runOneFrame] 里读 `getLastTimestampTrace` |
 * | 计数从 C++ 账本读，不在宿主语言合成 | `PWXrslamTransportGetCounters` | `PwXrslamTransport.getCounters` |
 *
 * ══ 与 iOS 的**四处显式差异**（都是平台事实，不是设计选择）═══════════════
 *
 * (1) **像素走 channel=1（luma8），不是 iOS 的 channel=4（BGRA）。**
 *     camera2 的 `ImageFormat.YUV_420_888` 的 Y 平面**就是** 8 位灰度，
 *     `pixelStride` 按规范恒为 1，直接就是引擎要的 `CV_8UC1`
 *     （`XRSLAMManager.cpp:143-145` @4beb1a9：`channel == 1` ⇒
 *     `cv::Mat(rows, cols, CV_8UC1, image->data, image->stride)` 且**不做
 *     cvtColor**）。iOS 走 BGRA 是因为 AVFoundation 的零拷贝格式是 BGRA；
 *     Android 这边零拷贝的就是 Y 平面，所以 channel=1 反而**少一次转换**。
 *
 * (2) **加速度原值直推，不乘 iOS 那个 `-9.80665`。**
 *     iOS 乘它是因为 CoreMotion 的 `CMAcceleration` 单位是 **g** 且符号与
 *     比力相反（Apple 文档：设备平放屏幕朝上时 z ≈ **−1.0** g），所以
 *     `value × (−9.80665)` 才得到 +9.80665 m/s²。
 *     Android 的 `TYPE_ACCELEROMETER` 文档口径是 **m/s²** 且平放屏幕朝上时
 *     z ≈ **+9.81**（Google `SensorEvent` 文档的第一个例子逐字如此）。
 *     ⇒ 两端换算后**同号同量纲**，Android 侧不需要任何标度或取反。
 *     🔴 **这一条是本文件唯一一处不能在本机证伪的换算**（无 Android 设备）。
 *     所以 [stats] 里报 `lastAccelMagnitude`：静置时它应 ≈ 9.8；
 *     若接近 1.0 说明单位错了，若 z 号相反说明符号错了。**报事实，不做判定。**
 *
 * (3) **相机时间戳的换算多一项 `skew/2`。**
 *     iOS 的卷帘读出时间不公开，只能连同管线固定延迟一起塞进每机常量 c。
 *     Android 公开：`CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW`（ns，API 21）。
 *     所以这里算的是
 *         `t_canonical = SENSOR_TIMESTAMP + EXPOSURE/2 + SKEW/2`
 *     依据不是自研：
 *       · `CaptureResult.SENSOR_TIMESTAMP` 官方文档口径是**首行曝光起点**；
 *       · Huai arXiv 2001.00470 §IV.B 的修正就是减去
 *         "half of the sum of [rolling shutter + exposure]"（我们是加到
 *         起点上，等价）；
 *       · 我们自己的契约 `xrslam-interface/include/XRSLAM.h` 条目 09 与
 *         `XRSLAMManager.cpp:92-99` 的换算同样是 `+0.5·exposure+0.5·readout`。
 *     `EXPOSURE`/`SKEW` 都是 **optional key**；缺哪个就按 0 计并计数
 *     （[framesWithoutExposure] / [framesWithoutSkew]），不伪造、不丢帧。
 *
 * (4) **时钟域**。`SensorEvent.timestamp` 是 `CLOCK_BOOTTIME`；
 *     `CaptureResult.SENSOR_TIMESTAMP` 只有在
 *     `SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME` 时才同域，`UNKNOWN` 时官方
 *     原话是 "monotonic but not comparable to timestamps from other
 *     subsystems"。差值 = 累计休眠时长，不是小量。
 *     🔴 本文件**不自己估这个偏移**：估计量（Cristian 最窄窗 best-of-N、
 *     单调性否决）已经在 `dart/pw_android_capture/lib/src/clock_offset.dart`
 *     里并有单元测试，README 的规矩是「判断放 Dart，Kotlin 只搬运」。
 *     调用方把结果作为 [create] 的 `cameraClockOffsetNs` 传进来；
 *     REALTIME 机器传 0。传了什么、加了多少，[timebase] 如实报出。
 *
 * ⚠️ 本文件**不解决**「引擎在 1920×1440 上跑不跑得到 30/60fps」。它只保证
 *    相机不被算法堵住、丢帧被如实计数归因（[framesDropped]）。
 */
class PwXrslamFeed {

    companion object {
        @JvmStatic
        val shared = PwXrslamFeed()

        private const val TAG = "PwXrslamFeed"

        /** 在途帧上限。取 2:一帧在算、一帧在等 —— 与 iOS 逐字相同。
         *  🔴 不能大:每一帧都占着 `ImageReader` 池里的一格
         *  (1920×1440 YUV_420_888 ≈ 4.1 MB),押太多帧会让 camera2 交不出
         *  buffer,那是把丢帧从我们的闸上推回给系统,归因就没了。 */
        private const val MAX_PENDING_FRAMES = 2

        /** IMU 在途上限。100 Hz × 4 s —— 与 iOS 逐字相同。 */
        private const val MAX_PENDING_IMU = 400

        /** 逐帧元数据环。相机结果与图像不保证同时到,按 SENSOR_TIMESTAMP 精确配对。 */
        private const val METADATA_RING = 16

        private const val NS_PER_S = 1.0e9
    }

    /** 一帧的相机元数据,来自 `CaptureResult`。全是 optional key,null 如实保留。 */
    data class FrameMetadata(
        val sensorTimestampNs: Long,
        val exposureTimeNs: Long?,
        val rollingShutterSkewNs: Long?,
    )

    private val lock = Any()

    // ── 两条线程:到达(串行,三流共享)/ 算法(串行) ────────────────────
    private var arrivalThread: HandlerThread? = null
    private var workThread: HandlerThread? = null

    /** 三条流的**共享串行到达上下文**。相机与 IMU 都挂它 ⇒ 入队顺序 = 物理到达顺序。 */
    var arrivalHandler: Handler? = null
        private set
    private var workHandler: Handler? = null

    private val transport = PwXrslamTransport()

    private var created = false
    /** 上游 `XRSLAMer.stopFlag` 的等价物:false 之前一律不推。 */
    private var running = false

    // ── 闸计数 ────────────────────────────────────────────────────────────
    private var pendingFrames = 0
    private var pendingImu = 0
    private var framesOffered = 0L
    private var framesDropped = 0L
    private var framesRejectedLayout = 0L
    private var imuDropped = 0L
    private var maxObservedPendingFrames = 0
    private var cameraCallbacks = 0L

    // ── 位姿 ──────────────────────────────────────────────────────────────
    private var haveResult = false
    private var lastState = 0
    private val lastPose = DoubleArray(8) // t qx qy qz qw px py pz

    // ── 跨流时钟域诊断(iOS 同名字段)────────────────────────────────────
    private var lastCameraRawSeconds = 0.0
    private var lastImuSeconds = 0.0
    private var lastDelta = 0.0
    private var maxAbsDelta = 0.0
    private var haveDelta = false
    /** 静置自证用:最近一条加速度样本的模。见类注释差异 (2)。 */
    private var lastAccelMagnitude = 0.0

    // ── 时基自证账本(iOS `timebase(into:)` 的逐项对应)────────────────
    private var cameraTimeOffsetSeconds = 0.0
    private var cameraClockOffsetNs = 0L
    private var tbFrames = 0L
    private var tbFramesWithExposure = 0L
    private var framesWithoutExposure = 0L
    private var framesWithoutSkew = 0L
    private var framesWithoutExactMetadata = 0L
    private var tbExposureSum = 0.0
    private var tbExposureMin = Double.MAX_VALUE
    private var tbExposureMax = 0.0
    private var tbHalfAppliedSum = 0.0
    private var tbTraceReads = 0L
    private var tbLastAppliedOffset = 0.0
    private var tbLastEffectiveMinusRaw = 0.0
    /** |C 收到的 raw − 我们推的 canonical| 峰值。**必须恒 0**。 */
    private var tbMaxAbsRawResidual = 0.0
    /** |(effective − raw) − applied_offset| 峰值。**必须恒 0**。 */
    private var tbMaxAbsOffsetResidual = 0.0

    private val traceOut = DoubleArray(6)
    private val countersOut = LongArray(9)

    // ── 逐帧元数据环 ──────────────────────────────────────────────────────
    private val metadataRing = arrayOfNulls<FrameMetadata>(METADATA_RING)
    private var metadataWrite = 0
    private var lastMetadata: FrameMetadata? = null

    // MARK: 生命周期

    /**
     * 建会话。返回沿用冻结的 `XRSLAMCreate` 口径:**1 成功 / 0 失败**。
     *
     * @param cameraTimeOffsetSeconds 每机常量 `c`(秒),由**传输层**在推相机
     *   样本前加到时间戳上(`PwXrslamTransportCore.cpp` `ValidateTimestampLocked`:
     *   `effective = raw + offset`),IMU 不动。取自 [PwDeviceCalibration]。
     * @param cameraClockOffsetNs `BOOTTIME − MONOTONIC`(ns),
     *   由调用方用 `clock_offset.dart` 的估计量算好传进来;
     *   `SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME` 的机器传 0。见类注释差异 (4)。
     */
    fun create(
        slamConfigPath: String,
        deviceConfigPath: String,
        cameraTimeOffsetSeconds: Double,
        cameraClockOffsetNs: Long,
    ): Int = synchronized(lock) {
        if (created) return 1

        this.cameraTimeOffsetSeconds =
            if (cameraTimeOffsetSeconds.isFinite()) cameraTimeOffsetSeconds else 0.0
        this.cameraClockOffsetNs = cameraClockOffsetNs
        resetLedgerLocked()

        val rc = transport.createWithCameraTimeOffset(
            slamConfigPath,
            deviceConfigPath,
            this.cameraTimeOffsetSeconds,
        )
        if (rc == 1) {
            created = true
            startThreadsLocked()
            Log.i(
                TAG,
                "created c=${this.cameraTimeOffsetSeconds}s " +
                    "clockOffset=${cameraClockOffsetNs}ns " +
                    "(${PwDeviceCalibration.cameraTimeOffsetProvenance().label})",
            )
        } else {
            Log.e(TAG, "XRSLAMCreate failed (rc=$rc) slam=$slamConfigPath dev=$deviceConfigPath")
        }
        return rc
    }

    private fun resetLedgerLocked() {
        tbFrames = 0; tbFramesWithExposure = 0
        framesWithoutExposure = 0; framesWithoutSkew = 0
        framesWithoutExactMetadata = 0
        tbExposureSum = 0.0; tbExposureMin = Double.MAX_VALUE; tbExposureMax = 0.0
        tbHalfAppliedSum = 0.0
        tbTraceReads = 0; tbLastAppliedOffset = 0.0; tbLastEffectiveMinusRaw = 0.0
        tbMaxAbsRawResidual = 0.0; tbMaxAbsOffsetResidual = 0.0
        framesOffered = 0; framesDropped = 0; framesRejectedLayout = 0
        imuDropped = 0; cameraCallbacks = 0
        maxObservedPendingFrames = 0; pendingFrames = 0; pendingImu = 0
        haveResult = false; lastState = 0
        haveDelta = false; lastDelta = 0.0; maxAbsDelta = 0.0
        lastCameraRawSeconds = 0.0; lastImuSeconds = 0.0; lastAccelMagnitude = 0.0
        metadataWrite = 0; lastMetadata = null
        for (i in metadataRing.indices) metadataRing[i] = null
    }

    private fun startThreadsLocked() {
        if (arrivalThread != null) return
        // 到达线程给 URGENT_AUDIO:抄 `PwImuSource` 里同一条理由 —— 忙碌的
        // looper 会把到达时刻抹平,让未批处理的投递看起来像批处理的。
        val a = HandlerThread("pw-vio-arrival", Process.THREAD_PRIORITY_URGENT_AUDIO)
        a.start()
        arrivalThread = a
        arrivalHandler = Handler(a.looper)

        val w = HandlerThread("pw-vio-work", Process.THREAD_PRIORITY_DISPLAY)
        w.start()
        workThread = w
        workHandler = Handler(w.looper)
    }

    /** 允许推送。必须在相机与 IMU 都挂上 [arrivalHandler] 之后调。
     *  @return 0 成功;-3 还没 create。 */
    fun begin(): Int = synchronized(lock) {
        if (!created) return -3
        running = true
        return 0
    }

    fun destroy() {
        val wasCreated: Boolean
        synchronized(lock) {
            wasCreated = created
            running = false
            created = false
            haveResult = false
        }
        arrivalThread?.quitSafely()
        workThread?.quitSafely()
        arrivalThread = null
        workThread = null
        arrivalHandler = null
        workHandler = null
        if (wasCreated) transport.destroy()
    }

    // MARK: 相机

    /**
     * 由 `CameraCaptureSession.CaptureCallback.onCaptureCompleted` 调。
     * 只记账,不做任何判断。
     */
    fun offerCaptureResult(meta: FrameMetadata) = synchronized(lock) {
        metadataRing[metadataWrite % METADATA_RING] = meta
        metadataWrite += 1
        lastMetadata = meta
        if (meta.exposureTimeNs == null) framesWithoutExposure += 1
        if (meta.rollingShutterSkewNs == null) framesWithoutSkew += 1
    }

    private fun findMetadataLocked(sensorTimestampNs: Long): FrameMetadata? {
        for (m in metadataRing) {
            if (m != null && m.sensorTimestampNs == sensorTimestampNs) return m
        }
        return null
    }

    /**
     * 由 `ImageReader.OnImageAvailableListener` 在 [arrivalHandler] 上调。
     *
     * 🔴 **只入队,不跑算法**(生产 `PwVioSlamFeeder.swift:9`:
     *    「回调只尝试有界入队,绝不等算法」)。在途满了就**计数丢弃**并立刻
     *    `close()`,让相机继续按自己的节奏交付。
     *
     * @param luma Y 平面的 **direct** `ByteBuffer`(`GetDirectBufferAddress` 要求)
     * @param rowStride Y 平面 `rowStride`
     * @param pixelStride Y 平面 `pixelStride`。YUV_420_888 规范里 Y 恒为 1;
     *   不为 1 就**不能**当 `CV_8UC1` 直推 ⇒ 计数拒绝,不静默错像素。
     * @param sensorTimestampNs `Image.getTimestamp()`,== `CaptureResult.SENSOR_TIMESTAMP`
     * @param release worker 用完后调它归还这一格(通常是 `image::close`)
     */
    fun offerFrame(
        luma: ByteBuffer,
        rowStride: Int,
        pixelStride: Int,
        sensorTimestampNs: Long,
        release: () -> Unit,
    ) {
        val canonicalSeconds: Double
        val rawSeconds: Double
        synchronized(lock) {
            if (!running) { release(); return }
            framesOffered += 1

            if (!luma.isDirect || pixelStride != 1 || rowStride <= 0) {
                framesRejectedLayout += 1
                release()
                return
            }

            // ── 曝光中点换算(类注释差异 (3))────────────────────────────
            val meta = findMetadataLocked(sensorTimestampNs)
            if (meta == null) framesWithoutExactMetadata += 1
            val used = meta ?: lastMetadata
            val exposureNs = used?.exposureTimeNs ?: 0L
            val skewNs = used?.rollingShutterSkewNs ?: 0L
            // 整数半:先加再除,避免两次截断。ns → s 只除一次。
            val halfNs = (exposureNs / 2.0) + (skewNs / 2.0)

            // 时钟域归一(类注释差异 (4))。REALTIME 机器 cameraClockOffsetNs == 0。
            val bootNs = sensorTimestampNs + cameraClockOffsetNs

            rawSeconds = bootNs / NS_PER_S
            canonicalSeconds = (bootNs + halfNs) / NS_PER_S

            lastCameraRawSeconds = rawSeconds
            tbFrames += 1
            if (exposureNs > 0) {
                val e = exposureNs / NS_PER_S
                tbFramesWithExposure += 1
                tbExposureSum += e
                if (e < tbExposureMin) tbExposureMin = e
                if (e > tbExposureMax) tbExposureMax = e
            }
            tbHalfAppliedSum += halfNs / NS_PER_S

            if (lastImuSeconds > 0) {
                lastDelta = rawSeconds - lastImuSeconds
                haveDelta = true
                val a = if (lastDelta < 0) -lastDelta else lastDelta
                if (a > maxAbsDelta) maxAbsDelta = a
            }

            if (pendingFrames >= MAX_PENDING_FRAMES) {
                framesDropped += 1
                release()
                return
            }
            pendingFrames += 1
            if (pendingFrames > maxObservedPendingFrames) {
                maxObservedPendingFrames = pendingFrames
            }
        }

        val h = workHandler
        if (h == null || !h.post {
                runOneFrame(luma, rowStride, canonicalSeconds, rawSeconds)
                release()
                synchronized(lock) { pendingFrames -= 1 }
            }
        ) {
            release()
            synchronized(lock) { pendingFrames -= 1; framesDropped += 1 }
        }
    }

    /**
     * 在 worker 上跑。与上游 `trackCamera`(`XRSLAM_iOS.mm:152-188`)同形:
     * push → RunOneFrame → GetResult 由传输层一次原子做完。
     */
    private fun runOneFrame(
        luma: ByteBuffer,
        rowStride: Int,
        canonicalSeconds: Double,
        rawSeconds: Double,
    ) {
        // channel = 1:Y 平面就是 CV_8UC1,引擎不做 cvtColor(类注释差异 (1))。
        val r = transport.pushCameraAndRunRaw(
            luma,
            canonicalSeconds,
            rowStride,
            /* cameraId = */ 0,
            /* channel  = */ 1,
        )

        // 时基自证:刚推完就读 C 账本里相机流的最近一条 trace。
        // workHandler 是串行的、只有这里推相机 ⇒ 读到的必是本帧。
        val trc = transport.getLastTimestampTrace(PwXrslamTransport.STREAM_CAMERA, traceOut)

        synchronized(lock) {
            cameraCallbacks += 1
            if (r.size >= 10 && r[0].toInt() == PwXrslamTransport.STATUS_OK) {
                lastState = r[1].toInt()
                // 🔴 只有 TRACKING_SUCCESS(1)才更新位姿 —— 抄上游
                //    XRSLAM_iOS.mm:171;其余状态下引擎返回的是陈旧/未定义值。
                if (lastState == 1) {
                    for (i in 0 until 8) lastPose[i] = r[2 + i]
                    haveResult = true
                }
            }
            if (trc == PwXrslamTransport.STATUS_OK &&
                traceOut[0].toInt() == PwXrslamTransport.STREAM_CAMERA
            ) {
                val rRaw = kotlin.math.abs(traceOut[2] - canonicalSeconds)
                val rOff = kotlin.math.abs((traceOut[4] - traceOut[2]) - traceOut[3])
                tbTraceReads += 1
                tbLastAppliedOffset = traceOut[3]
                tbLastEffectiveMinusRaw = traceOut[4] - rawSeconds
                if (rRaw > tbMaxAbsRawResidual) tbMaxAbsRawResidual = rRaw
                if (rOff > tbMaxAbsOffsetResidual) tbMaxAbsOffsetResidual = rOff
            }
        }
    }

    // MARK: IMU

    /**
     * 由 [PwImuSource] 的 sink 在 [arrivalHandler] 上调。
     *
     * 🔴 **分开推、各带自己的时间戳、不配对**。iOS 那一版曾把陀螺和加速度
     *    配成一对、两条都盖陀螺的时间戳,实测 `skew=4.987ms`(正好半个采样
     *    周期),二次积分几十秒就是几十米。这里一条样本推一次。
     * 🔴 **先陀螺后加速度**由注册顺序保证:`PwImuSource.start()` 的 `wanted`
     *    列表把陀螺放在前面,两条流又都在同一条 [arrivalHandler] 上到达。
     *
     * @param type `SensorEvent.sensor.type`
     * @param eventTsNs `SensorEvent.timestamp`(`CLOCK_BOOTTIME`)
     * @param values `SensorEvent.values`。uncalibrated 流的 [0..2] 是未补偿值、
     *   [3..5] 是 HAL 的偏置估计 —— 我们只取 [0..2],偏置交给估计器自己估。
     */
    fun onImuSample(type: Int, eventTsNs: Long, values: FloatArray) {
        if (values.size < 3) return
        val t = eventTsNs / NS_PER_S
        val x = values[0].toDouble()
        val y = values[1].toDouble()
        val z = values[2].toDouble()

        when (type) {
            Sensor.TYPE_GYROSCOPE, Sensor.TYPE_GYROSCOPE_UNCALIBRATED -> {
                synchronized(lock) { lastImuSeconds = t }
                // rad/s,原样透传(上游 Motion.swift:47 也是原值)。
                enqueueImu { transport.pushGyroscope(t, x, y, z) }
            }

            Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_ACCELEROMETER_UNCALIBRATED -> {
                synchronized(lock) {
                    lastImuSeconds = t
                    lastAccelMagnitude = kotlin.math.sqrt(x * x + y * y + z * z)
                }
                // m/s²,原样透传。**不乘 iOS 那个 −9.80665**,见类注释差异 (2)。
                enqueueImu { transport.pushAcceleration(t, x, y, z) }
            }

            else -> return
        }
    }

    /** IMU 入队的公共部分:闸 → post → 在 worker 上推。回调**只做这些**。 */
    private fun enqueueImu(push: () -> Unit) {
        synchronized(lock) {
            if (!running) return
            if (pendingImu >= MAX_PENDING_IMU) {
                imuDropped += 1
                return
            }
            pendingImu += 1
        }
        val h = workHandler
        if (h == null || !h.post {
                push()
                synchronized(lock) { pendingImu -= 1 }
            }
        ) {
            synchronized(lock) { pendingImu -= 1; imuDropped += 1 }
        }
    }

    // MARK: 读出

    /** 9 个 double:state t qx qy qz qw px py pz。返回 0 有位姿 / −1 还没有。 */
    fun latest(out: DoubleArray): Int = synchronized(lock) {
        if (out.size < 9) return -2
        out[0] = lastState.toDouble()
        for (i in 0 until 8) out[1 + i] = lastPose[i]
        return if (haveResult) 0 else -1
    }

    /** 5 个 double:最近相机原始时刻、最近 IMU 时刻、两者之差、|差| 峰值、
     *  最近加速度模(静置应 ≈ 9.8,见类注释差异 (2))。返回 0 有样本 / −1 还没有。 */
    fun timing(out: DoubleArray): Int = synchronized(lock) {
        if (out.size < 5) return -2
        out[0] = lastCameraRawSeconds
        out[1] = lastImuSeconds
        out[2] = lastDelta
        out[3] = maxAbsDelta
        out[4] = lastAccelMagnitude
        return if (haveDelta) 0 else -1
    }

    /**
     * 15 个 double —— 相机时间戳换算的运行期自证。前 12 项与 iOS
     * `PwXrslamLive.timebase(into:)` **逐位对应**,后 3 项是 Android 独有的
     * 元数据缺失计数(iOS 没有 skew 这个键)。
     *
     *   0 c 传入值(秒)          1 c 实际施加值(C 账本 applied_offset)
     *   2 帧数                   3 其中曝光>0 的帧数
     *   4 曝光均值  5 曝光最小  6 曝光最大(秒;3 为 0 时 4/5 写 0)
     *   7 平均实际加上的 (exposure+skew)/2(秒)
     *   8 |C 收到的 raw − 我们推的 canonical| 峰值   **必须 0**
     *   9 |(effective−raw) − applied_offset| 峰值     **必须 0**
     *  10 引擎收到的时刻 − 归一后的原始时刻(最近一帧,秒)= (exp+skew)/2 + c
     *  11 trace 读取次数
     *  12 缺 EXPOSURE 的结果数   13 缺 SKEW 的结果数
     *  14 没配到精确元数据的帧数(退回了上一帧的曝光/skew)
     *
     * 返回 0 = 已有 trace;−1 = 还没推过帧。
     */
    fun timebase(out: DoubleArray): Int = synchronized(lock) {
        if (out.size < 15) return -2
        out[0] = cameraTimeOffsetSeconds
        out[1] = tbLastAppliedOffset
        out[2] = tbFrames.toDouble()
        out[3] = tbFramesWithExposure.toDouble()
        out[4] = if (tbFramesWithExposure > 0) tbExposureSum / tbFramesWithExposure else 0.0
        out[5] = if (tbFramesWithExposure > 0) tbExposureMin else 0.0
        out[6] = tbExposureMax
        out[7] = if (tbFrames > 0) tbHalfAppliedSum / tbFrames else 0.0
        out[8] = tbMaxAbsRawResidual
        out[9] = tbMaxAbsOffsetResidual
        out[10] = tbLastEffectiveMinusRaw
        out[11] = tbTraceReads.toDouble()
        out[12] = framesWithoutExposure.toDouble()
        out[13] = framesWithoutSkew.toDouble()
        out[14] = framesWithoutExactMetadata.toDouble()
        return if (tbTraceReads > 0) 0 else -1
    }

    /**
     * 16 个 int64。**前 9 个直接来自 C++ 账本**,不在 Kotlin 里合成
     * (`PwXrslamTransportCore.h` 原话 "Swift must not synthesize them",
     * 对 Kotlin 同样成立);后 7 个是本文件自己的入队闸计数。
     *
     *  0 lifecycleGeneration  1 cameraSubmitted  2 cameraRunCalls
     *  3 accelerationSubmitted 4 gyroscopeSubmitted
     *  5 rejectedInvalidArgument 6 rejectedNonMonotonic 7 rejectedNotRunning
     *  8 running
     *  9 cameraCallbacks 10 framesOffered 11 framesDropped
     * 12 framesRejectedLayout 13 imuDropped 14 maxObservedPendingFrames
     * 15 metadataResultsSeen
     */
    fun stats(out: LongArray): Int {
        if (out.size < 16) return -2
        transport.getCounters(countersOut)
        synchronized(lock) {
            for (i in 0 until 9) out[i] = countersOut[i]
            out[9] = cameraCallbacks
            out[10] = framesOffered
            out[11] = framesDropped
            out[12] = framesRejectedLayout
            out[13] = imuDropped
            out[14] = maxObservedPendingFrames.toLong()
            out[15] = metadataWrite.toLong()
        }
        return 0
    }

    /**
     * 🔴 时基自证的**判定行**。与 iOS 的 `[arloop] 时基` 一行同形,
     * 落 logcat 供真机取证。两条残差**必须恒 0**;不为 0 说明我们推给
     * 传输层的时间戳与传输层收到的不是同一个数,整场归因作废。
     */
    fun logTimebase() {
        val tb = DoubleArray(15)
        val rc = timebase(tb)
        if (rc != 0) {
            Log.w(TAG, "[pwvio] 时基: 还没有 trace (rc=$rc, frames=${tb[2].toLong()})")
            return
        }
        Log.i(
            TAG,
            "[pwvio] 时基 c传入=${tb[0] * 1000}ms c施加=${tb[1] * 1000}ms " +
                "帧=${tb[2].toLong()} 有曝光=${tb[3].toLong()} " +
                "曝光均值=${tb[4] * 1000}ms [${tb[5] * 1000},${tb[6] * 1000}] " +
                "半程均值=${tb[7] * 1000}ms " +
                "|raw残差|=${tb[8]} |offset残差|=${tb[9]} " +
                "effective−raw=${tb[10] * 1000}ms trace读=${tb[11].toLong()} " +
                "缺曝光=${tb[12].toLong()} 缺skew=${tb[13].toLong()} " +
                "缺精确元数据=${tb[14].toLong()}",
        )
        if (tb[8] != 0.0 || tb[9] != 0.0) {
            Log.e(
                TAG,
                "🔴 时基自证失败: |raw−canonical|=${tb[8]} |(eff−raw)−offset|=${tb[9]} " +
                    "—— 两者必须恒 0,本场归因作废",
            )
        }
    }
}
