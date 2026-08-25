package com.pocketworld.capture

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock

/**
 * Thermal signal source. Contains the platform calls and NOTHING else: every
 * threshold, hysteresis band and action lives in `ThermalPolicy` on the Dart
 * side, where it is unit tested.
 *
 * getThermalHeadroom (API 30) is rate limited, and the two Google sources give
 * different bounds:
 *   android.os.PowerManager reference -- NaN if called "significantly faster
 *     than once per second".
 *   ADPF thermal guide -- "You shouldn't call it more than once every 10
 *     seconds"; "If getThermalHeadroom returns NaN, make sure that you are not
 *     calling it more than once every 10 seconds."
 * We obey the stricter one. [MIN_POLL_INTERVAL_MS] here is a second, redundant
 * guard: the Dart policy already refuses to hand out a poll slot sooner, so a
 * violation would need both layers to be wrong.
 *
 * The guide also says "Avoid calling from multiple threads": [sample] is
 * synchronized and this object is the single owner of the call.
 */
class PwThermalWatch(context: Context) {

    companion object {
        const val MIN_POLL_INTERVAL_MS = 10_000L

        /** getThermalHeadroom's forecast horizon, in seconds. 0 == "right now". */
        const val FORECAST_NOW = 0
    }

    private val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    private var lastPollMs = 0L
    private var everPolled = false

    private var listener: PowerManager.OnThermalStatusChangedListener? = null

    /**
     * @param onStatus receives PowerManager.THERMAL_STATUS_* (0..6). This is a
     *   push signal and is NOT rate limited; only the headroom poll is.
     */
    fun startStatusListener(onStatus: (Int) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        stopStatusListener()
        val l = PowerManager.OnThermalStatusChangedListener { status -> onStatus(status) }
        power.addThermalStatusListener(l)
        listener = l
        // The listener only fires on CHANGE, so seed the current value or the
        // first change is the first thing Dart ever learns about temperature.
        onStatus(power.currentThermalStatus)
    }

    fun stopStatusListener() {
        val l = listener ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            power.removeThermalStatusListener(l)
        }
        listener = null
    }

    fun currentStatus(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) power.currentThermalStatus else 0

    /**
     * One thermal sample, in the shape `ThermalSample` expects.
     *
     * `headroom` is Double.NaN when the API is unavailable, when the device has
     * no thermal HAL, or when we were called too soon. Dart distinguishes those
     * cases; this method never substitutes a number for a missing reading.
     *
     * `throttled` is true when this call was suppressed by the local guard, so
     * a caller that ignores the Dart-side gate can still see it happened.
     */
    @Synchronized
    fun sample(): Map<String, Any> {
        val now = SystemClock.elapsedRealtime()
        val due = !everPolled || (now - lastPollMs) >= MIN_POLL_INTERVAL_MS
        var headroom = Double.NaN
        var throttled = false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // getThermalHeadroom does not exist before API 30. Status only.
        } else if (!due) {
            throttled = true
        } else {
            lastPollMs = now
            everPolled = true
            headroom = power.getThermalHeadroom(FORECAST_NOW).toDouble()
        }
        return mapOf(
            "atMs" to now,
            "headroom" to headroom,
            "status" to currentStatus(),
            "throttledLocally" to throttled,
            "headroomApiAvailable" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R),
        )
    }
}
