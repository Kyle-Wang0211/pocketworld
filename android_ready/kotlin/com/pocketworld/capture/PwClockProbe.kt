package com.pocketworld.capture

import android.os.Process
import android.os.SystemClock

/**
 * Reads the two monotonic clocks back to back so Dart can estimate
 * BOOTTIME - MONOTONIC.
 *
 *   System.nanoTime()                     -> CLOCK_MONOTONIC (stops in suspend)
 *   SystemClock.elapsedRealtimeNanos()    -> CLOCK_BOOTTIME  (keeps ticking)
 *
 * Both are plain vDSO reads, so a probe costs well under a microsecond unless
 * the thread is descheduled between the reads. The ONLY defence against that is
 * to take several probes and let the estimator keep the narrowest; this class
 * deliberately contains no selection logic of its own -- see
 * `dart/pw_android_capture/lib/src/clock_offset.dart`, which is unit tested.
 *
 * Needed only when CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE reports
 * SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN. On REALTIME devices the camera stamp is
 * already in the SensorEvent.timestamp base and nothing here runs.
 */
object PwClockProbe {

    /** Wire shape consumed by ClockProbe in Dart: [monoBefore, boot, monoAfter]. */
    fun probe(count: Int = 9): List<LongArray> {
        val out = ArrayList<LongArray>(count)
        val previous = Process.getThreadPriority(Process.myTid())
        // URGENT_AUDIO, not a real-time priority: it lowers the chance of being
        // descheduled mid-probe without letting a bad probe through. Correctness
        // still comes from best-of-N in Dart, never from the priority.
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        } catch (_: SecurityException) {
            // Priority is an optimisation. Losing it is not an error.
        }
        try {
            for (i in 0 until count) {
                val monoBefore = System.nanoTime()
                val boot = SystemClock.elapsedRealtimeNanos()
                val monoAfter = System.nanoTime()
                out.add(longArrayOf(monoBefore, boot, monoAfter))
            }
        } finally {
            try {
                Process.setThreadPriority(previous)
            } catch (_: SecurityException) {
            }
        }
        return out
    }

    /** MethodChannel-friendly form. */
    fun probeForChannel(count: Int = 9): List<Map<String, Any>> =
        probe(count).map {
            mapOf(
                "monoBeforeNs" to it[0],
                "bootNs" to it[1],
                "monoAfterNs" to it[2],
            )
        }
}
