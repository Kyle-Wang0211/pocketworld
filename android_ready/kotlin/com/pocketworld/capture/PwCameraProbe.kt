package com.pocketworld.capture

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.graphics.ImageFormat
import android.os.Build

/**
 * Camera2 reads and request tuning for a VIO capture.
 *
 * WHAT WE READ (CameraCharacteristics)
 *   SENSOR_INFO_TIMESTAMP_SOURCE              Key<Integer>
 *     REALTIME(1) -> CaptureResult.SENSOR_TIMESTAMP is already on
 *     elapsedRealtimeNanos(), i.e. the SensorEvent.timestamp base.
 *     UNKNOWN(0)  -> "monotonic but not comparable to timestamps from other
 *     subsystems". Every frame stamp must be shifted by the measured
 *     BOOTTIME-MONOTONIC offset before it can be fused with IMU. This single
 *     integer decides whether PwClockProbe needs to run at all.
 *
 *   LENS_INTRINSIC_CALIBRATION                Key<float[]>  (optional key)
 *     [f_x, f_y, c_x, c_y, s]. Since API 28 it is expressed in pixels of the
 *     PRE-CORRECTION active array, which is why we also read
 *     SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE -- reading it against the
 *     post-correction array silently misplaces the principal point.
 *
 *   LENS_DISTORTION                           Key<float[]>  (API 28)
 *     [k1, k2, k3, k4, k5, k6]... Brown-Conrady radial+tangential. Replaces the
 *     deprecated LENS_RADIAL_DISTORTION, which used a different parameterisation.
 *
 *   Both intrinsic keys are OPTIONAL. A null here is a normal device, not a
 *   fault: it means self-calibration, not a failed capture.
 *
 * WHAT WE TURN OFF (CaptureRequest)
 *   CONTROL_VIDEO_STABILIZATION_MODE -> OFF
 *   LENS_OPTICAL_STABILIZATION_MODE  -> OFF
 *     EIS warps the image per frame and OIS physically moves the lens. Both
 *     break the rigid camera-IMU transform that VIO is built on: the pose the
 *     IMU reports is no longer the pose the pixels were taken from.
 *   DISTORTION_CORRECTION_MODE       -> OFF   (API 28)
 *     Geometric correction is ON by default on most devices. With it on, the
 *     effective intrinsics are the corrected ones and LENS_DISTORTION no longer
 *     describes the image you received. Turning it off is what makes the
 *     published intrinsics usable as-is.
 *
 *   Each is applied ONLY after checking the corresponding availability list.
 *   Setting an unsupported key is not a no-op in camera2 -- it can make the
 *   whole request fail -- so an unsupported control is reported, not forced.
 */
object PwCameraProbe {

    fun characteristics(manager: CameraManager, cameraId: String): Map<String, Any?> {
        val c = manager.getCameraCharacteristics(cameraId)

        val tsSource = c.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
        val pre = c.get(CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE)
        val active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val pixelArray = c.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)

        val out = HashMap<String, Any?>()
        out["cameraId"] = cameraId
        // Marshalled as Int, compared in Dart against TimestampSource.realtime.
        // Null means the device did not publish the key: treat as UNKNOWN, i.e.
        // assume conversion is needed. Assuming REALTIME would silently fuse
        // two unrelated clocks.
        out["timestampSource"] = tsSource ?: CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN
        out["timestampSourceWasNull"] = (tsSource == null)

        out["preCorrectionActiveArray"] =
            pre?.let { listOf(it.left, it.top, it.right, it.bottom) }
        out["activeArray"] = active?.let { listOf(it.left, it.top, it.right, it.bottom) }
        out["pixelArray"] = pixelArray?.let { listOf(it.width, it.height) }
        // Row count SENSOR_TIMESTAMP and SENSOR_ROLLING_SHUTTER_SKEW refer to.
        out["activeArrayHeight"] = pre?.height() ?: active?.height()

        out["intrinsicCalibration"] =
            c.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)?.map { it.toDouble() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            out["distortion"] = c.get(CameraCharacteristics.LENS_DISTORTION)?.map { it.toDouble() }
            out["poseReference"] = c.get(CameraCharacteristics.LENS_POSE_REFERENCE)
            out["distortionCorrectionAvailableModes"] =
                c.get(CameraCharacteristics.DISTORTION_CORRECTION_AVAILABLE_MODES)?.toList()
        }
        out["poseRotation"] = c.get(CameraCharacteristics.LENS_POSE_ROTATION)?.map { it.toDouble() }
        out["poseTranslation"] = c.get(CameraCharacteristics.LENS_POSE_TRANSLATION)?.map { it.toDouble() }

        out["availableVideoStabilizationModes"] =
            c.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)?.toList()
        out["availableOpticalStabilization"] =
            c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)?.toList()
        out["hardwareLevel"] = c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
        out["capabilities"] = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList()

        // [ENTRY-ANY-4X3 2026-09-25] 照片尺寸候选 —— 只查不判。用户规则「不同手机就用 4:3 能做到的
        // 最大尺寸」的判定在 Dart(pocketworld lib/vio/capture/photo_size_rule.dart
        // pickLargestFourByThree,与 iOS 同一份);这里原样报出官方 API 的两张表:
        //   StreamConfigurationMap.getOutputSizes(ImageFormat.JPEG)                (API 21)
        //   StreamConfigurationMap.getHighResolutionOutputSizes(ImageFormat.JPEG)  (API 23,
        //     BURST_CAPTURE 设备上可能更大但更慢)
        // SENSOR_ORIENTATION 一并报出:入口判据按**传感器方向的原始像素网格**判 4:3,拍照请求
        // 应保持 JPEG_ORIENTATION = 0(像素不转、朝向只写 EXIF),否则部分设备会把像素转成竖向,
        // 入口会以 NOT_SENSOR_ORIENTATION(4)拒收。
        // ⚠️ 本目录 Kotlin 从未编译过(见 README);这段同样只对照了官方参考文档。
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        out["jpegOutputSizes"] =
            map?.getOutputSizes(ImageFormat.JPEG)?.map { listOf(it.width, it.height) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            out["jpegHighResolutionOutputSizes"] =
                map?.getHighResolutionOutputSizes(ImageFormat.JPEG)?.map { listOf(it.width, it.height) }
        }
        out["sensorOrientation"] = c.get(CameraCharacteristics.SENSOR_ORIENTATION)
        return out
    }

    /**
     * Applies the stabilisation/correction OFF policy to [b].
     * @return which controls were actually applied, for the capture log. A
     *   control the device does not list is left alone and reported as absent.
     */
    fun applyVioTuning(
        c: CameraCharacteristics,
        b: CaptureRequest.Builder,
    ): Map<String, Boolean> {
        val applied = HashMap<String, Boolean>()

        val eisModes = c.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
        val eisOffSupported =
            eisModes?.contains(CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF) == true
        if (eisOffSupported) {
            b.set(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
            )
        }
        applied["videoStabilizationOff"] = eisOffSupported

        val oisModes = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
        val oisOffSupported =
            oisModes?.contains(CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_OFF) == true
        if (oisOffSupported) {
            b.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_OFF,
            )
        }
        applied["opticalStabilizationOff"] = oisOffSupported

        var dcOffSupported = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val dcModes = c.get(CameraCharacteristics.DISTORTION_CORRECTION_AVAILABLE_MODES)
            dcOffSupported =
                dcModes?.contains(CameraMetadata.DISTORTION_CORRECTION_MODE_OFF) == true
            if (dcOffSupported) {
                b.set(
                    CaptureRequest.DISTORTION_CORRECTION_MODE,
                    CameraMetadata.DISTORTION_CORRECTION_MODE_OFF,
                )
            }
        }
        applied["distortionCorrectionOff"] = dcOffSupported
        return applied
    }

    /**
     * Per-frame metadata, in the shape `FrameMetadata` expects on the Dart side.
     *
     * SENSOR_TIMESTAMP is documented as the FIRST ROW exposure start, not the
     * middle of the frame. SENSOR_EXPOSURE_TIME and SENSOR_ROLLING_SHUTTER_SKEW
     * are OPTIONAL keys; a null becomes a null here and the Dart side marks the
     * resulting stamp `degraded` rather than pretending the correction is
     * complete or dropping the frame.
     */
    fun frameMetadata(
        r: TotalCaptureResult,
        activeArrayHeight: Int,
    ): Map<String, Any?> = mapOf(
        "frameNumber" to r.frameNumber,
        "sensorTimestampNs" to r.get(CaptureResult.SENSOR_TIMESTAMP),
        "exposureTimeNs" to r.get(CaptureResult.SENSOR_EXPOSURE_TIME),
        "rollingShutterSkewNs" to r.get(CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW),
        "frameDurationNs" to r.get(CaptureResult.SENSOR_FRAME_DURATION),
        "activeArrayHeight" to activeArrayHeight,
        // Reported so a per-frame change of the applied policy is visible in
        // the log instead of only in the trajectory.
        "appliedVideoStabilizationMode" to r.get(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE),
        "appliedOpticalStabilizationMode" to r.get(CaptureResult.LENS_OPTICAL_STABILIZATION_MODE),
    )
}
