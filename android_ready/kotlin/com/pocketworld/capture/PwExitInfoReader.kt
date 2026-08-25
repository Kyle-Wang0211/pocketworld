package com.pocketworld.capture

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

/**
 * Reads ActivityManager.getHistoricalProcessExitReasons (API 30) and marshals
 * it. Classification is NOT done here -- it lives in `ExitTriage` on the Dart
 * side, where the Android 17 memory-limiter rule is unit tested.
 *
 * The case this exists for, in Google's own words (Android Developers Blog,
 * 2026-06):
 *   "If an app exceeds those limits, Android will kill the process with no
 *    associated stack trace."
 *   "the exit reason is reported as REASON_OTHER and the description string
 *    will contain MemoryLimiter:AnonSwap"
 * A native VIO map is anonymous memory, which is exactly what AnonSwap
 * accounts, so this is the most likely way a long capture dies on Android 17 --
 * and the only such death that leaves no crash, no ANR and no tombstone. If we
 * do not read it at the next launch, it is invisible forever.
 *
 * getDescription() is @Nullable; a null is marshalled as "" so the Dart
 * substring test cannot throw. Note that the empty string never matches
 * "MemoryLimiter:AnonSwap", so this cannot manufacture a false positive.
 */
object PwExitInfoReader {

    /** @param maxNum 0 means "no limit" per the platform docs. */
    fun read(context: Context, maxNum: Int = 32): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val infos: List<ApplicationExitInfo> = try {
            am.getHistoricalProcessExitReasons(context.packageName, 0, maxNum)
        } catch (_: SecurityException) {
            return emptyList()
        }
        return infos.map { toMap(it) }
    }

    private fun toMap(i: ApplicationExitInfo): Map<String, Any> {
        val m = HashMap<String, Any>()
        m["timestampMs"] = i.timestamp
        m["pid"] = i.pid
        m["reason"] = i.reason
        m["description"] = i.description ?: ""
        m["status"] = i.status
        m["importance"] = i.importance
        // Both are documented "in kB", and both are zero when the system never
        // got to sample the process before it died -- which is common for the
        // very kills we care about. Passed through as-is; a zero is reported as
        // a zero, never patched up.
        m["rssKb"] = i.rss
        m["pssKb"] = i.pss
        m["processName"] = i.processName ?: ""
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            m["subReason"] = i.subReason
        }
        return m
    }
}
