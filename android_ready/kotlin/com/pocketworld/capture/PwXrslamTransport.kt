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
    private external fun nativePushCameraAndRunRawWithIntrinsics(
        data: ByteBuffer,
        timestampSeconds: Double,
        stride: Int,
        cameraId: Int,
        channel: Int,
        intrinsicsFxFyCxCy: DoubleArray?,
    ): DoubleArray
    private external fun nativeIntrinsicsTrace(): DoubleArray
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

    /**
     * Same `[transportRc,state,timestamp,qx,qy,qz,qw,tx,ty,tz]` transaction as
     * [pushCameraAndRunRaw], optionally carrying this frame's pinhole intrinsics
     * (shared C++ `PWXrslamTransportPushCameraAndRunRawWithIntrinsics`).
     *
     * [intrinsicsFxFyCxCy] `null` = byte-for-byte the legacy push. Otherwise
     * exactly four values fx, fy, cx, cy **in pixels of [data] as pushed**,
     * pixel-center-at-integer convention (the convention of the engine and of
     * ARKit's `ARCamera.intrinsics`). An array whose length is not 4 is not
     * attached: the frame is still pushed without per-frame K (legacy push)
     * and counted as `rejected_invalid` in [intrinsicsTrace], the same outcome
     * as a non-finite or non-positive K on iOS.
     *
     * TODO(per-frame-K, Android source): not wired to camera2 yet — there is no
     * Android frame path calling this, and the mapping below cannot be verified
     * without a device. What the official camera2 documentation fixes
     * (AOSP frameworks/base core/java/android/hardware/camera2/CaptureResult.java,
     * LENS_INTRINSIC_CALIBRATION / SCALER_CROP_REGION / DISTORTION_CORRECTION_MODE):
     *  - per-frame source: `CaptureResult.LENS_INTRINSIC_CALIBRATION`
     *    `[f_x, f_y, c_x, c_y, s]`, optional (may be null); fallback
     *    `CameraCharacteristics.LENS_INTRINSIC_CALIBRATION`.
     *  - its coordinate system is `SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE`,
     *    (0,0) = top-left of that rectangle, and "the center of pixel (x,y) is
     *    located at coordinate (x + 0.5, y + 0.5)" — the corner convention, so
     *    the engine value is c - 0.5 after mapping, and the ARKit-convention
     *    downsample formula (c + 0.5) / d - 0.5 must not be applied to it as-is.
     *  - the pushed YUV buffer is the final crop region (in pre-correction
     *    coordinates when DISTORTION_CORRECTION_MODE is OFF, which
     *    PwCameraProbe.applyVioTuning requests), further cropped centered to the
     *    output aspect ratio, then scaled to the output size; the crop actually
     *    used is in `CaptureResult.SCALER_CROP_REGION`; CONTROL_ZOOM_RATIO and
     *    SENSOR_PIXEL_MODE change the reference array.
     *  - with distortion correction OFF the buffer is not undistorted:
     *    `LENS_DISTORTION` still applies on top of this K.
     * Until those steps are implemented and checked on a device, callers pass
     * `null` (engine uses the yaml K, the legacy behavior).
     */
    fun pushCameraAndRunRawWithIntrinsics(
        data: ByteBuffer,
        timestampSeconds: Double,
        stride: Int,
        cameraId: Int,
        channel: Int,
        intrinsicsFxFyCxCy: DoubleArray?,
    ): DoubleArray = nativePushCameraAndRunRawWithIntrinsics(
        data,
        timestampSeconds,
        stride,
        cameraId,
        channel,
        intrinsicsFxFyCxCy,
    )

    /**
     * Raw copy of the shared C++ per-frame intrinsics ledger
     * (`PWXrslamIntrinsicsTrace`), see PwXrslamTransport.cpp for the order.
     * Kotlin does not interpret it.
     */
    fun intrinsicsTrace(): DoubleArray = nativeIntrinsicsTrace()

    fun pushAcceleration(timestampSeconds: Double, x: Double, y: Double, z: Double) =
        nativePushAcceleration(timestampSeconds, x, y, z)

    fun pushGyroscope(timestampSeconds: Double, x: Double, y: Double, z: Double) =
        nativePushGyroscope(timestampSeconds, x, y, z)

}
