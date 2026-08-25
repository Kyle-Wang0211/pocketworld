package com.pocketworld.capture

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock

/**
 * IMU registration, done the one way that keeps a VIO front end fed.
 *
 * THE BATCHING RULE
 *   registerListener(listener, sensor, samplingPeriodUs, maxReportLatencyUs)
 *   turns on hardware FIFO batching for any maxReportLatencyUs > 0. Batched
 *   delivery hands a whole burst of samples to one callback, which is the
 *   arrival pattern that degenerates xrslam's gyro/accel interleave
 *   (xrslam/src/xrslam/core/detail.cpp): a batch of gyro arriving all at once
 *   drains the queued accelerometer buffer a sample at a time. We therefore
 *   pass maxReportLatencyUs = 0 -- and then VERIFY the result, because like the
 *   sampling period this is only a request. The verification lives in
 *   `SensorDeliveryMonitor` on the Dart side and is unit tested there.
 *
 * THE RATE RULE
 *   samplingPeriodUs is documented as a hint, not a contract ("the delay you
 *   specify is only a suggestion"). Apps targeting API 31+ are additionally
 *   capped at 200 Hz for accelerometer / gyroscope / magnetometer unless the
 *   manifest declares android.permission.HIGH_SAMPLING_RATE_SENSORS -- a
 *   normal (install-time) permission, so there is no runtime request to make
 *   and no user prompt, but there is also NO API that reports the achieved
 *   rate. It has to be reconstructed from the timestamps.
 *
 * DELIVERY THREAD
 *   A dedicated HandlerThread, so a busy main looper cannot smear arrivalTsNs
 *   and make unbatched delivery look batched.
 *
 * NO DATA LOSS
 *   onSensorChanged hands every event to [sink] with no filtering, no
 *   decimation and no reordering. Backpressure, if any, is the sink's business
 *   and may only postpone.
 */
class PwImuSource(
    context: Context,
    private val sink: (type: Int, eventTsNs: Long, arrivalTsNs: Long, values: FloatArray) -> Unit,
) : SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private val registered = ArrayList<Sensor>()

    /** Sensors we ask for, in priority order. Uncalibrated first when present:
     *  the HAL bias estimate is a moving target that a VIO estimator wants to
     *  own itself, and the uncalibrated stream also carries the bias so nothing
     *  is lost by preferring it. */
    private fun pick(primary: Int, fallback: Int): Sensor? =
        sensorManager.getDefaultSensor(primary) ?: sensorManager.getDefaultSensor(fallback)

    fun describe(): Map<String, Any?> {
        val gyro = pick(Sensor.TYPE_GYROSCOPE_UNCALIBRATED, Sensor.TYPE_GYROSCOPE)
        val accel = pick(Sensor.TYPE_ACCELEROMETER_UNCALIBRATED, Sensor.TYPE_ACCELEROMETER)
        return mapOf(
            "gyro" to describeSensor(gyro),
            "accel" to describeSensor(accel),
        )
    }

    private fun describeSensor(s: Sensor?): Map<String, Any?>? {
        if (s == null) return null
        return mapOf(
            "name" to s.name,
            "vendor" to s.vendor,
            "type" to s.type,
            // Microseconds. The fastest rate the sensor claims it can produce.
            // Still only a claim: the achieved rate is measured, not read.
            "minDelayUs" to s.minDelay,
            "maxDelayUs" to s.maxDelay,
            // A non-zero FIFO is what makes batching possible at all. Reported
            // so the Dart side knows whether a `batched` flag is even plausible
            // or points at something stranger.
            "fifoReservedEventCount" to s.fifoReservedEventCount,
            "fifoMaxEventCount" to s.fifoMaxEventCount,
            "resolution" to s.resolution,
            "maximumRange" to s.maximumRange,
            "power" to s.power,
        )
    }

    /**
     * @param samplingPeriodUs 0 == SENSOR_DELAY_FASTEST. Above API 31 this is
     *   clamped to 200 Hz unless HIGH_SAMPLING_RATE_SENSORS is in the manifest.
     * @return the sensors the platform accepted. A sensor missing from this
     *   list was refused by registerListener and must be surfaced, not ignored.
     */
    fun start(samplingPeriodUs: Int = 0): List<String> {
        stop()
        val t = HandlerThread("pw-imu", Process.THREAD_PRIORITY_URGENT_AUDIO)
        t.start()
        thread = t
        val h = Handler(t.looper)
        handler = h

        val wanted = listOfNotNull(
            pick(Sensor.TYPE_GYROSCOPE_UNCALIBRATED, Sensor.TYPE_GYROSCOPE),
            pick(Sensor.TYPE_ACCELEROMETER_UNCALIBRATED, Sensor.TYPE_ACCELEROMETER),
        )
        for (s in wanted) {
            val ok = sensorManager.registerListener(
                this,
                s,
                samplingPeriodUs,
                // MUST stay 0. Any positive value enables hardware batching.
                0,
                h,
            )
            if (ok) registered.add(s)
        }
        return registered.map { it.name }
    }

    fun stop() {
        if (registered.isNotEmpty()) {
            sensorManager.unregisterListener(this)
            registered.clear()
        }
        thread?.quitSafely()
        thread = null
        handler = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        // Read the arrival clock FIRST and on this thread: it is the whole
        // measurement. SensorEvent.timestamp is BOOTTIME, so arrival must be
        // elapsedRealtimeNanos() and not nanoTime(), or the two are not
        // comparable and every delivery would look batched.
        val arrival = SystemClock.elapsedRealtimeNanos()
        sink(event.sensor.type, event.timestamp, arrival, event.values.copyOf())
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Accuracy transitions are informational for an uncalibrated stream.
        // Deliberately not used to gate or drop samples.
    }
}
