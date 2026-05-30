import Darwin
import Flutter
import Foundation
import UIKit
#if canImport(os)
import os
#endif

@objc final class DeviceHealthPlugin: NSObject {
  @objc static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "pocketworld/device_health",
      binaryMessenger: messenger
    )
    let plugin = DeviceHealthPlugin()
    channel.setMethodCallHandler { call, result in
      plugin.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sampleDeviceHealth":
      result(Self.systemSnapshot())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func systemSnapshot() -> [String: Any] {
    let processInfo = ProcessInfo.processInfo
    let jetsamAvailable = jetsamAvailableMemoryMB()
    let oneCoreCpu = processCpuOneCorePercent()
    let logicalCores = max(1, processInfo.processorCount)
    return [
      "status": "ok",
      "source": "ios_device_health_plugin",
      "sampledAtUtc": ISO8601DateFormatter().string(from: Date()),
      "rssMB": residentMemoryMB() as Any,
      "availableMemoryMB": jetsamAvailable as Any,
      "jetsamAvailableMB": jetsamAvailable as Any,
      "thermalState": thermalStateString(processInfo.thermalState),
      "thermalStateRaw": processInfo.thermalState.rawValue,
      "cpuOneCorePercent": oneCoreCpu,
      "cpuDeviceNormalizedPercent": oneCoreCpu / Double(logicalCores),
      "logicalCores": logicalCores,
      "lowPowerModeEnabled": processInfo.isLowPowerModeEnabled,
      "processorCount": processInfo.processorCount,
      "activeProcessorCount": processInfo.activeProcessorCount,
      "physicalMemoryMB": Double(processInfo.physicalMemory) / 1024.0 / 1024.0,
      "applicationState": applicationStateString(),
    ]
  }

  private static func residentMemoryMB() -> Double? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          rebound,
          &count
        )
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Double(info.resident_size) / 1024.0 / 1024.0
  }

  private static func jetsamAvailableMemoryMB() -> Double? {
    #if os(iOS)
    return Double(os_proc_available_memory()) / 1024.0 / 1024.0
    #else
    return nil
    #endif
  }

  private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown_\(state.rawValue)"
    }
  }

  private static func applicationStateString() -> String {
    switch UIApplication.shared.applicationState {
    case .active:
      return "active"
    case .inactive:
      return "inactive"
    case .background:
      return "background"
    @unknown default:
      return "unknown_\(UIApplication.shared.applicationState.rawValue)"
    }
  }

  private static func processCpuOneCorePercent() -> Double {
    var threadList: thread_act_array_t?
    var threadCount = mach_msg_type_number_t(0)
    let threadsResult = task_threads(
      mach_task_self_,
      &threadList,
      &threadCount
    )
    guard threadsResult == KERN_SUCCESS, let threadList else {
      return 0.0
    }
    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threadList)),
        vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
      )
    }

    var total = 0.0
    for index in 0..<Int(threadCount) {
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(THREAD_INFO_MAX)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
          thread_info(
            threadList[index],
            thread_flavor_t(THREAD_BASIC_INFO),
            rebound,
            &count
          )
        }
      }
      guard result == KERN_SUCCESS else { continue }
      if (info.flags & TH_FLAGS_IDLE) == 0 {
        total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
      }
    }
    return total
  }
}
