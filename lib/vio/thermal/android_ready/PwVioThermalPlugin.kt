// PwVioThermalPlugin.kt — Android 侧热信号采集(ready-to-drop)。
//
// ⚠️⚠️ 状态声明:**这个文件从未被编译过。**
// /Users/kaidongwang/Developer/pocketworld 里**没有 android/ 目录** —— Android
// 应用根本不存在,这台机器上也没装 Android SDK。所以本文件是按已核实的 API
// 文档写的骨架,不是验证过的产物。落地时必须先编译一次再信它。
// (Dart 侧与 iOS 侧都是**实际跑过测试 / 实际过了类型检查**的,只有这个不是。)
//
// 落位:<app>/android/app/src/main/kotlin/com/pocketworld/vio/PwVioThermalPlugin.kt
// 需要 compileSdk >= 30。minSdk 无要求(全部 API 都有 Build.VERSION 守卫)。
//
// ── 设计约束:这里**只上报原始值,不判档** ──────────────────────────────
// 档位折叠(七级 → 四级)、headroom 抬档、迟滞,全部在 Dart 侧
// lib/vio/thermal/ 里做,与 iOS 共用同一份实现。平台层一旦自己判档,
// 两端就会跑出结构性不同的行为。
//
// ── 已核实的 API(出处写在每一条后面)────────────────────────────────────
// * PowerManager.addThermalStatusListener(Executor, OnThermalStatusChangedListener)
//     API 29 起。(Mono.Android binding 的 [Register(..., ApiSince=29)] 佐证)
// * PowerManager.getThermalHeadroom(int forecastSeconds)
//     API 30 起。([Register(..., ApiSince=30)])
//     返回值:>= 0.0 的 float,**1.0 == THERMAL_STATUS_SEVERE 阈**,可以 > 1.0。
//     官方原文:"Returns NaN if the device does not support this functionality
//     or if this function is called significantly faster than once per second."
//     ADPF 指南进一步要求:"You shouldn't call it more than once every 10 seconds."
//     ⇒ 本文件把节流硬编成 10s(见 HEADROOM_MIN_INTERVAL_MS),
//       并且 **NaN 一律上报成 null,绝不上报 0.0** —— 0.0 会被读成"完全没热压力"。
// * THERMAL_STATUS_*(与 NDK AThermalStatus 同值):
//     NONE=0 LIGHT=1 MODERATE=2 SEVERE=3 CRITICAL=4 EMERGENCY=5 SHUTDOWN=6
//
// ── 没有做的事 ──────────────────────────────────────────────────────────
// /proc 与 /sys 的读取**故意不放在这里**。那些全是读文本 + 解析,dart:io 在
// Android 上直接能读,放 Dart 才能在 Mac 上离机单测 —— 见
// lib/vio/thermal/proc_cpu_probe.dart(其中 /proc/<pid>/stat 的 comm 字段
// 可含空格与右括号这个静默错位陷阱,已由单测钉死)。

package com.pocketworld.vio

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

class PwVioThermalPlugin :
    FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "pocketworld_vio_thermal"
        const val EVENT_CHANNEL = "pocketworld_vio_thermal/events"

        /** ADPF:getThermalHeadroom 每 10s 最多一次,更频繁会返回 NaN。 */
        const val HEADROOM_MIN_INTERVAL_MS = 10_000L

        /** 预测窗口(秒)。0 = 取当前值。 */
        const val HEADROOM_FORECAST_SECONDS = 0
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var powerManager: PowerManager? = null
    private var appContext: Context? = null

    private var lastHeadroomAtMs = 0L
    private var lastHeadroom: Double? = null

    /** 最近一次拿到的 THERMAL_STATUS_*;-1 表示还没读到过。 */
    private var lastStatus: Int = -1
    private var statusReadable = false

    private val mainExecutor: Executor
        get() = appContext!!.mainExecutor

    private val thermalListener =
        PowerManager.OnThermalStatusChangedListener { status ->
            lastStatus = status
            statusReadable = true
            emit()
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        powerManager =
            binding.applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopListening()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        appContext = null
        powerManager = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> { startListening(); result.success(null) }
            "stop" -> { stopListening(); result.success(null) }
            "snapshot" -> result.success(snapshot())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        startListening()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stopListening()
    }

    private fun startListening() {
        val pm = powerManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) { // API 29
            // 先同步取一次当前状态,别等第一次回调。
            lastStatus = pm.currentThermalStatus
            statusReadable = true
            pm.addThermalStatusListener(mainExecutor, thermalListener)
        }
        emit()
    }

    private fun stopListening() {
        val pm = powerManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching { pm.removeThermalStatusListener(thermalListener) }
        }
    }

    /**
     * 取 thermal headroom,带 10s 节流。
     * 返回 null 的三种情况一律读作"拿不到",**不可读作 0**:
     *   1. API < 30;2. 设备不支持(返回 NaN);3. 距上次调用不足 10s(复用缓存)。
     */
    private fun readHeadroom(): Double? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null // API 30
        val pm = powerManager ?: return null
        val now = SystemClock.elapsedRealtime()
        if (now - lastHeadroomAtMs < HEADROOM_MIN_INTERVAL_MS) {
            return lastHeadroom // 复用上一次的值,绝不重复调用触发 NaN
        }
        lastHeadroomAtMs = now
        val v = runCatching { pm.getThermalHeadroom(HEADROOM_FORECAST_SECONDS) }
            .getOrNull()
        lastHeadroom = if (v == null || v.isNaN()) null else v.toDouble()
        return lastHeadroom
    }

    /** 字段名必须与 lib/vio/thermal/thermal_signal.dart 的 decodeThermalSignal 逐字一致。 */
    private fun snapshot(): Map<String, Any?> {
        val map = HashMap<String, Any?>()
        map["schema"] = 1
        map["platform"] = "android"
        map["tsUs"] = SystemClock.elapsedRealtimeNanos() / 1000L
        map["rawStatus"] = lastStatus
        map["statusReadable"] = statusReadable
        // headroom 为 null 时**不放这个 key**;放 null/0 都会被误读。
        readHeadroom()?.let { map["headroom"] = it }
        // 相机状态由采集层("camera2 / CameraX 的 session 回调")喂进来;
        // 本插件不猜。未知就报 unknown。
        map["cameraStream"] = cameraStream
        // lowPowerMode / interruptionReason / systemPressure* 是 iOS 专有,
        // 这里**一个都不放** —— Dart 侧解成 null。
        return map
    }

    /** 由采集层在 camera session 打开/关闭/出错时调用。 */
    @Volatile
    var cameraStream: String = "unknown"

    private fun emit() {
        sink?.success(snapshot())
    }
}
