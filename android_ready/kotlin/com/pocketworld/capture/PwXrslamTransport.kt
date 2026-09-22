package com.pocketworld.capture

import java.nio.ByteBuffer

/** Raw JNI transport for the frozen five-function XRSLAM ABI.
 *
 * This class makes no state, quality, pacing, or pose decision. Dart owns the
 * two config files and interprets the raw array returned by
 * [pushCameraAndRunRaw].
 */
class PwXrslamTransport {
    companion object {
        init {
            System.loadLibrary("pw_xrslam_transport")
        }
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

}
