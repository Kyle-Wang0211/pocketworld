package com.pocketworld.capture

import java.nio.ByteBuffer

/** Raw JNI transport for the frozen five-function XRSLAM ABI.
 *
 * This class makes no state, quality, pacing, or pose decision. Dart owns the
 * two config files and interprets the raw array returned by
 * [pushCameraAndRunRaw].
 */
class PwXrslamTransport {
    init {
        loadOnce()
    }

    private external fun nativeCreate(
        slamConfigPath: String,
        deviceConfigPath: String,
    ): Int
    private external fun nativeDestroy()
    private external fun nativePushCameraAndRunRaw(
        data: ByteBuffer,
        timestampSeconds: Double,
        stride: Int,
        cameraId: Int,
        channel: Int,
    ): DoubleArray
    private external fun nativePushAcceleration(
        timestampSeconds: Double,
        x: Double,
        y: Double,
        z: Double,
    ): Int
    private external fun nativePushGyroscope(
        timestampSeconds: Double,
        x: Double,
        y: Double,
        z: Double,
    ): Int

    // ── [pw 2026-09-22] 接线补的三个 extern ───────────────────────────────
    // 与 `native/xrslam/PwXrslamTransport.cpp` 里同名的三个 JNI 出口一一对应。
    // 🔴 「绑定存在 ≠ 符号存在」:这三个的存在由构建后的 `nm -D` 对照证明
    //    (见 `android_ready/native/xrslam/build_transport.sh` 的符号闸),
    //    不是由这份声明证明。
    private external fun nativeCreateWithCameraTimeOffset(
        slamConfigPath: String,
        deviceConfigPath: String,
        cameraTimeOffsetSeconds: Double,
    ): Int
    private external fun nativeGetLastTimestampTrace(
        stream: Int,
        out: DoubleArray,
    ): Int
    private external fun nativeGetCounters(out: LongArray): Int

    fun create(slamConfigPath: String, deviceConfigPath: String): Int =
        nativeCreate(slamConfigPath, deviceConfigPath)

    fun destroy() = nativeDestroy()

    /**
     * `[transportRc,state,timestamp,qx,qy,qz,qw,tx,ty,tz]`.
     * The shared C++ transport performs the same fixed push/run/raw-read
     * transaction as iOS. Kotlin does not classify any element.
     */
    fun pushCameraAndRunRaw(
        data: ByteBuffer,
        timestampSeconds: Double,
        stride: Int,
        cameraId: Int,
        channel: Int,
    ): DoubleArray = nativePushCameraAndRunRaw(
        data,
        timestampSeconds,
        stride,
        cameraId,
        channel,
    )

    fun pushAcceleration(timestampSeconds: Double, x: Double, y: Double, z: Double) =
        nativePushAcceleration(timestampSeconds, x, y, z)

    fun pushGyroscope(timestampSeconds: Double, x: Double, y: Double, z: Double) =
        nativePushGyroscope(timestampSeconds, x, y, z)

    /**
     * Create with the per-device constant `c` applied inside the shared C++
     * transport, exactly as iOS does
     * (`ios/Runner/PwXrslamLive.swift` `create(...)`).
     *
     * `c` is the part of the camera time offset that cannot be computed from
     * camera2 metadata (fixed pipeline latency). The part that *can* be
     * computed -- `exposure/2 + rolling_shutter_skew/2` -- is applied by the
     * feed before the timestamp reaches this class; see [PwXrslamFeed].
     *
     * Returns the frozen `XRSLAMCreate` convention: 1 success, 0 failure.
     */
    fun createWithCameraTimeOffset(
        slamConfigPath: String,
        deviceConfigPath: String,
        cameraTimeOffsetSeconds: Double,
    ): Int = nativeCreateWithCameraTimeOffset(
        slamConfigPath,
        deviceConfigPath,
        cameraTimeOffsetSeconds,
    )

    /**
     * `out[6] = [stream, status, rawTimestamp, appliedOffset,
     *            effectiveTimestamp, submittedSequence]`, read from the C++
     * ledger. Kotlin does not synthesize any of it -- the header says
     * "Swift must not synthesize them" and the same applies here.
     */
    fun getLastTimestampTrace(stream: Int, out: DoubleArray): Int =
        nativeGetLastTimestampTrace(stream, out)

    /**
     * `out[9] = [lifecycleGeneration, cameraSubmitted, cameraRunCalls,
     *            accelerationSubmitted, gyroscopeSubmitted,
     *            rejectedInvalidArgument, rejectedNonMonotonic,
     *            rejectedNotRunning, running]`.
     */
    fun getCounters(out: LongArray): Int = nativeGetCounters(out)

    companion object Streams {
        @Volatile private var loaded = false

        @Synchronized
        private fun loadOnce() {
            if (loaded) return
            System.loadLibrary("pw_xrslam_transport")
            loaded = true
        }

        /** Mirrors `PWXrslamStream` in `PwXrslamTransportCore.h`. */
        const val STREAM_CAMERA = 0
        const val STREAM_ACCELERATION = 1
        const val STREAM_GYROSCOPE = 2

        /** Mirrors `PWXrslamTransportStatus.PW_XRSLAM_OK`. */
        const val STATUS_OK = 0
    }
}
