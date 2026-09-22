package com.pocketworld.capture

import android.content.Context
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import java.io.File
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
    // [pw 2026-09-22] VIO 喂料链。相机源在这里被持有,IMU 复用上面那个 `imu`
    // 字段但挂到 feed 的串行到达 handler 上(见 `startVio`)。
    private var camera: PwVioCameraSource? = null
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
        camera?.close()
        camera = null
        PwXrslamFeed.shared.destroy()
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

                // ══ [pw 2026-09-22] VIO 喂料链 ══════════════════════════
                // 🔴 分工照 README 的规矩:**判断在 Dart,Kotlin 只搬运**。
                //   · 内参换算(LENS_INTRINSIC_CALIBRATION 是 pre-correction
                //     active array 像素,不是输出流像素)由 Dart 做,算好的
                //     fx/fy/cx/cy 从参数传进来。这里不缩放、不猜。
                //   · BOOTTIME−MONOTONIC 偏移由 `clock_offset.dart` 的估计量
                //     算好传进来(REALTIME 机器传 0)。
                //   · slam yaml 由 Dart 写盘后把路径传进来(与 iOS 同口径)。
                // Kotlin 这边只负责:写 device yaml、建会话、起相机与 IMU、
                // 把账本原样报回去。
                "startVio" -> {
                    val slamConfigPath = call.argument<String>("slamConfigPath")
                    if (slamConfigPath == null) {
                        result.error("startVio", "slamConfigPath is required", null)
                        return
                    }
                    val feed = PwXrslamFeed.shared

                    val extrinsic = PwDeviceCalibration.forThisDevice()
                    val provenanceArg = call.argument<String>("intrinsicsProvenance")
                    val intrinsicsProvenance =
                        PwDeviceCalibration.Provenance.values().asList()
                            .firstOrNull { it.label == provenanceArg }
                            ?: PwDeviceCalibration.Provenance.PLACEHOLDER
                    val placeholders =
                        PwDeviceCalibration.logProvenance(extrinsic, intrinsicsProvenance)

                    val yaml = PwDeviceCalibration.buildDeviceConfigYaml(
                        fx = call.argument<Double>("fx") ?: 0.0,
                        fy = call.argument<Double>("fy") ?: 0.0,
                        cx = call.argument<Double>("cx") ?: 0.0,
                        cy = call.argument<Double>("cy") ?: 0.0,
                        width = call.argument<Int>("width") ?: 0,
                        height = call.argument<Int>("height") ?: 0,
                        intrinsicsProvenance = intrinsicsProvenance,
                        extrinsic = extrinsic,
                        distortion = call.argument<List<Double>>("distortion")?.toDoubleArray(),
                    )
                    val deviceConfig = File(context.filesDir, "device_config.yaml")
                    deviceConfig.writeText(yaml)

                    val rc = feed.create(
                        slamConfigPath = slamConfigPath,
                        deviceConfigPath = deviceConfig.absolutePath,
                        cameraTimeOffsetSeconds =
                            PwDeviceCalibration.cameraTimeOffsetSeconds(),
                        cameraClockOffsetNs =
                            (call.argument<Number>("cameraClockOffsetNs") ?: 0).toLong(),
                    )
                    if (rc != 1) {
                        result.success(
                            mapOf("createRc" to rc, "placeholders" to placeholders),
                        )
                        return
                    }

                    // 🔴 三条流共享 feed 的串行到达上下文(上游 `.main` 的等价物)。
                    val arrival = feed.arrivalHandler
                    val cam = PwVioCameraSource(context, arrival!!, feed)
                    val openRc = cam.open()
                    camera = cam

                    imu?.stop()
                    val src = PwImuSource(context) { type, eventTs, _, values ->
                        feed.onImuSample(type, eventTs, values)
                    }
                    val started = src.start(
                        call.argument<Int>("samplingPeriodUs") ?: 0,
                        arrival,
                    )
                    imu = src
                    feed.begin()

                    result.success(
                        mapOf(
                            "createRc" to rc,
                            "cameraOpenRc" to openRc,
                            "imuRegistered" to started,
                            "deviceConfigPath" to deviceConfig.absolutePath,
                            "deviceKey" to PwDeviceCalibration.deviceKey(),
                            "placeholders" to placeholders,
                            "selection" to cam.describeSelection(),
                        ),
                    )
                }

                "stopVio" -> {
                    camera?.close()
                    camera = null
                    imu?.stop()
                    imu = null
                    PwXrslamFeed.shared.destroy()
                    result.success(null)
                }

                "vioStats" -> {
                    val stats = LongArray(16)
                    val rc = PwXrslamFeed.shared.stats(stats)
                    result.success(mapOf("rc" to rc, "values" to stats.toList()))
                }

                // 时基自证。`rawResidual` / `offsetResidual` **必须恒 0**。
                "vioTimebase" -> {
                    val tb = DoubleArray(15)
                    val rc = PwXrslamFeed.shared.timebase(tb)
                    PwXrslamFeed.shared.logTimebase()
                    result.success(mapOf("rc" to rc, "values" to tb.toList()))
                }

                "vioTiming" -> {
                    val t = DoubleArray(5)
                    val rc = PwXrslamFeed.shared.timing(t)
                    result.success(mapOf("rc" to rc, "values" to t.toList()))
                }

                "vioLatestPose" -> {
                    val pose = DoubleArray(9)
                    val rc = PwXrslamFeed.shared.latest(pose)
                    result.success(mapOf("rc" to rc, "values" to pose.toList()))
                }

                "vioSelection" -> result.success(camera?.describeSelection())

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error(call.method, t.message, t.stackTraceToString())
        }
    }
}
