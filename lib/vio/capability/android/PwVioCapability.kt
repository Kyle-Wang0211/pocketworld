// PwVioCapability.kt — Android Camera2/Core clock raw transport adapter.
//
// This file intentionally contains no VIO eligibility, calibration usability,
// timebase-relation, stabilization-state, or rolling-shutter policy. It copies
// bounded platform facts to Dart, where the cross-platform decisions live.
//
// The product does not yet contain an Android Gradle application. This draft
// has therefore not passed assembleDebug and must remain marked uncompiled
// until it is moved into a real Android module and compiled against its pinned
// SDK. The guards below state the runtime API boundary; they are not a claim of
// binary validation on Android hardware.

package com.pocketworld.vio

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.os.Build
import android.os.SystemClock

private object PwVioIntrinsicsSource {
    const val NONE = "none"
    const val STATIC_CHARACTERISTICS = "staticCharacteristics"
}

object PwVioCapability {
    /**
     * Copies the Camera2 timestamp-source integer and one tight
     * CLOCK_MONOTONIC/CLOCK_BOOTTIME/CLOCK_MONOTONIC sandwich.
     * Offset, uncertainty, and clock-domain relation are derived in Dart.
     */
    @JvmStatic
    fun timebaseWire(characteristics: CameraCharacteristics): Map<String, Any?> {
        val timestampSource = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
        } else {
            null
        }
        val monotonicBeforeNanos = System.nanoTime()
        val bootRealtimeNanos = if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1
        ) {
            SystemClock.elapsedRealtimeNanos()
        } else {
            null
        }
        val monotonicAfterNanos = System.nanoTime()
        return mapOf(
            "schema" to "pw.vio.android.timebase-raw/1",
            "timestampSource" to timestampSource,
            "monotonicBeforeNanos" to monotonicBeforeNanos,
            "bootRealtimeNanos" to bootRealtimeNanos,
            "monotonicAfterNanos" to monotonicAfterNanos,
        )
    }

    /**
     * Existing static-intrinsics transport. The platform arrays are widened
     * from Float to Double because Flutter's StandardMessageCodec has no Float
     * scalar wire type. No focal-length or remapping math runs here.
     */
    @JvmStatic
    fun intrinsicsWire(characteristics: CameraCharacteristics): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return absentIntrinsicsWire()
        }
        val intrinsics =
            characteristics.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
        val reference = characteristics.get(
            CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE,
        )
        if (intrinsics == null || intrinsics.size < 5 || reference == null) {
            return absentIntrinsicsWire()
        }
        return mapOf(
            "source" to PwVioIntrinsicsSource.STATIC_CHARACTERISTICS,
            "fx" to intrinsics[0].toDouble(),
            "fy" to intrinsics[1].toDouble(),
            "cx" to intrinsics[2].toDouble(),
            "cy" to intrinsics[3].toDouble(),
            "skew" to intrinsics[4].toDouble(),
            "referenceWidth" to reference.width(),
            "referenceHeight" to reference.height(),
        )
    }

    private fun absentIntrinsicsWire(): Map<String, Any?> = mapOf(
        "source" to PwVioIntrinsicsSource.NONE,
        "fx" to 0.0,
        "fy" to 0.0,
        "cx" to 0.0,
        "cy" to 0.0,
        "skew" to 0.0,
        "referenceWidth" to 0,
        "referenceHeight" to 0,
    )

    /** Copies the optional Android distortion array without fitting a model. */
    @JvmStatic
    fun distortionWire(characteristics: CameraCharacteristics): Map<String, Any?> {
        val coefficients = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            characteristics.get(CameraCharacteristics.LENS_DISTORTION)
                ?.takeIf { it.size >= 5 }
                ?.map { it.toDouble() }
        } else {
            null
        }
        return mapOf("coefficients" to coefficients)
    }

    /**
     * Copies the optional Camera2 pose reference and arrays. In particular,
     * Kotlin does not decide whether a reference is suitable for camera/gyro
     * calibration; Dart interprets the raw reference integer.
     */
    @JvmStatic
    fun extrinsicsWire(characteristics: CameraCharacteristics): Map<String, Any?> {
        val poseReference = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            characteristics.get(CameraCharacteristics.LENS_POSE_REFERENCE)
        } else {
            null
        }
        val translation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            characteristics.get(CameraCharacteristics.LENS_POSE_TRANSLATION)
                ?.takeIf { it.size == 3 }
                ?.let {
                    listOf(it[0].toDouble(), it[1].toDouble(), it[2].toDouble())
                }
        } else {
            null
        }
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            characteristics.get(CameraCharacteristics.LENS_POSE_ROTATION)
                ?.takeIf { it.size == 4 }
                ?.let {
                    listOf(
                        it[0].toDouble(),
                        it[1].toDouble(),
                        it[2].toDouble(),
                        it[3].toDouble(),
                    )
                }
        } else {
            null
        }
        return mapOf(
            "schema" to "pw.vio.android.extrinsics-raw/1",
            "poseReference" to poseReference,
            "translationMeters" to translation,
            "rotationXyzw" to rotation,
        )
    }

    /**
     * Applies the two raw Camera2 mode integers selected by Dart. A null value
     * means “do not set this request key”; Kotlin supplies no fallback target.
     */
    @JvmStatic
    fun applyStabilizationModes(
        builder: CaptureRequest.Builder,
        requestedElectronicMode: Int?,
        requestedOpticalMode: Int?,
    ) {
        if (requestedElectronicMode != null) {
            builder.set(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                requestedElectronicMode,
            )
        }
        if (requestedOpticalMode != null) {
            builder.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                requestedOpticalMode,
            )
        }
    }

    /**
     * Echoes availability, Dart's request, and the platform readback as raw
     * integers. Classification of modes is exclusively a Dart concern.
     */
    @JvmStatic
    fun stabilizationWire(
        characteristics: CameraCharacteristics,
        result: TotalCaptureResult,
        requestedElectronicMode: Int?,
        requestedOpticalMode: Int?,
    ): Map<String, Any?> = mapOf(
        "schema" to "pw.vio.android.stabilization-raw/1",
        "availableElectronicModes" to characteristics.get(
            CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES,
        )?.toList(),
        "availableOpticalModes" to characteristics.get(
            CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION,
        )?.toList(),
        "requestedElectronicMode" to requestedElectronicMode,
        "requestedOpticalMode" to requestedOpticalMode,
        "actualElectronicMode" to result.get(
            CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE,
        ),
        "actualOpticalMode" to result.get(
            CaptureResult.LENS_OPTICAL_STABILIZATION_MODE,
        ),
    )

    /**
     * Copies full-array skew and both row counts without scaling, clamping, or
     * substituting a missing output-row count. Dart owns the conversion.
     */
    @JvmStatic
    fun rollingShutterWire(
        characteristics: CameraCharacteristics,
        result: TotalCaptureResult,
        outputRowsCoveringActiveArray: Int?,
    ): Map<String, Any?> {
        val activeArrayHeight = characteristics.get(
            CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE,
        )?.height()
        return mapOf(
            "schema" to "pw.vio.android.rolling-shutter-raw/1",
            "skewNs" to result.get(CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW),
            "activeArrayHeight" to activeArrayHeight,
            "outputRowsCoveringActiveArray" to outputRowsCoveringActiveArray,
        )
    }

    /** Copies Camera2's hardware-level integer without naming or ranking it. */
    @JvmStatic
    fun hardwareLevelWire(characteristics: CameraCharacteristics): Map<String, Any?> = mapOf(
        "schema" to "pw.vio.android.hardware-level-raw/1",
        "hardwareLevel" to characteristics.get(
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL,
        ),
    )
}

/** One unmodified SensorEvent.timestamp/delivery-clock pair. */
private data class PwVioImuArrival(
    val sampleTsNs: Long,
    val deliveryTsNs: Long,
)

/**
 * Fixed-capacity transport storage for raw IMU arrival pairs.
 *
 * The ring reports exact attempted/retained/overwritten accounting. It does
 * not infer sampling rate, batching, permission relevance, or health.
 */
class PwVioImuArrivalRing(private val capacity: Int = 4096) {
    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    private val arrivals = arrayOfNulls<PwVioImuArrival>(capacity)
    private var writeIndex = 0
    private var retainedCount = 0
    private var attemptedCount = 0L

    @Synchronized
    fun append(sampleTsNs: Long, deliveryTsNs: Long) {
        attemptedCount += 1L
        arrivals[writeIndex] = PwVioImuArrival(sampleTsNs, deliveryTsNs)
        writeIndex = (writeIndex + 1) % capacity
        if (retainedCount < capacity) {
            retainedCount += 1
        }
    }

    @Synchronized
    fun wire(available: Boolean): Map<String, Any?> {
        val oldestIndex = if (retainedCount == capacity) writeIndex else 0
        val sampleTsNs = ArrayList<Long>(retainedCount)
        val deliveryTsNs = ArrayList<Long>(retainedCount)
        for (offset in 0 until retainedCount) {
            val index = (oldestIndex + offset) % capacity
            val arrival = checkNotNull(arrivals[index])
            sampleTsNs.add(arrival.sampleTsNs)
            deliveryTsNs.add(arrival.deliveryTsNs)
        }
        val overwrittenCount = attemptedCount - retainedCount.toLong()
        return mapOf(
            "schema" to "pw.vio.imu-arrivals.raw.v1",
            "available" to available,
            "sampleTsNs" to sampleTsNs,
            "deliveryTsNs" to deliveryTsNs,
            "attemptedCount" to attemptedCount,
            "retainedCount" to retainedCount,
            "overwrittenCount" to overwrittenCount,
            "capacity" to capacity,
        )
    }

    @Synchronized
    fun reset() {
        arrivals.fill(null)
        writeIndex = 0
        retainedCount = 0
        attemptedCount = 0L
    }
}
