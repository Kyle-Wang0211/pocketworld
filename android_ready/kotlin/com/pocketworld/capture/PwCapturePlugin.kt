package com.pocketworld.capture

import android.content.Context
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Marshalling only. Every decision -- which probe to trust, whether delivery is
 * batched, when to back off thermally, what killed the last process -- is made
 * by the pure-Dart core in `pw_android_capture`, which has unit tests. Nothing
 * in this file may grow a threshold or a policy.
 *
 * Registration, either of:
 *   flutterEngine.plugins.add(PwCapturePlugin())          // from MainActivity
 *   // or let the embedding discover it as a normal FlutterPlugin
 */
class PwCapturePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "pocketworld/android_capture"
        const val IMU_EVENT_CHANNEL = "pocketworld/android_capture/imu"
    }

    private lateinit var context: Context
    private lateinit var method: MethodChannel
    private lateinit var imuEvents: EventChannel

    private var imu: PwImuSource? = null
    private var thermal: PwThermalWatch? = null
    private var imuSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        thermal = PwThermalWatch(context)

        method = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        method.setMethodCallHandler(this)

        imuEvents = EventChannel(binding.binaryMessenger, IMU_EVENT_CHANNEL)
        imuEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                imuSink = events
            }

            override fun onCancel(arguments: Any?) {
                imuSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        imu?.stop()
        imu = null
        thermal?.stopStatusListener()
        thermal = null
        method.setMethodCallHandler(null)
        imuEvents.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "probeClocks" -> {
                    val n = (call.argument<Int>("count") ?: 9).coerceIn(1, 64)
                    result.success(PwClockProbe.probeForChannel(n))
                }

                "describeImu" -> {
                    val src = imu ?: PwImuSource(context) { _, _, _, _ -> }
                    result.success(src.describe())
                }

                "startImu" -> {
                    imu?.stop()
                    // samplingPeriodUs 0 == SENSOR_DELAY_FASTEST. Above API 31
                    // the platform clamps to 200 Hz unless the manifest carries
                    // HIGH_SAMPLING_RATE_SENSORS. Either way the achieved rate
                    // is measured in Dart, never assumed here.
                    val periodUs = call.argument<Int>("samplingPeriodUs") ?: 0
                    val src = PwImuSource(context) { type, eventTs, arrivalTs, values ->
                        val payload = mapOf(
                            "type" to type,
                            "eventTsNs" to eventTs,
                            "arrivalTsNs" to arrivalTs,
                            // Double, not Float: StandardMessageCodec cannot encode a
                            // 32-bit float, and it fails on device, not here.
                            "values" to values.map { it.toDouble() },
                        )
                        // EventSink is main-thread only; the IMU callback is on
                        // the dedicated HandlerThread. Posting keeps the sample
                        // intact -- it postpones delivery, it never drops it.
                        main.post { imuSink?.success(payload) }
                    }
                    val started = src.start(periodUs)
                    imu = src
                    result.success(started)
                }

                "stopImu" -> {
                    imu?.stop()
                    imu = null
                    result.success(null)
                }

                "cameraCharacteristics" -> {
                    val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    val id = call.argument<String>("cameraId")
                        ?: mgr.cameraIdList.firstOrNull()
                    if (id == null) {
                        result.error("no_camera", "no camera ids reported", null)
                    } else {
                        result.success(PwCameraProbe.characteristics(mgr, id))
                    }
                }

                "thermalSample" -> result.success(thermal?.sample())

                "startThermalStatus" -> {
                    thermal?.startStatusListener { status ->
                        main.post {
                            method.invokeMethod("onThermalStatus", mapOf("status" to status))
                        }
                    }
                    result.success(null)
                }

                "stopThermalStatus" -> {
                    thermal?.stopStatusListener()
                    result.success(null)
                }

                "exitInfo" -> {
                    val maxNum = call.argument<Int>("maxNum") ?: 32
                    result.success(PwExitInfoReader.read(context, maxNum))
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error(call.method, t.message, t.stackTraceToString())
        }
    }
}
