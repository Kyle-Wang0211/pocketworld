import Foundation

struct DeviceIdentity: Equatable {
    let modelIdentifier: String

    static func current() -> DeviceIdentity {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return DeviceIdentity(modelIdentifier: identifier)
    }
}

enum LiveCalibrationGate {
    static let frozenModelIdentifier = "iPhone15,2"

    static func rejectionReason(for device: DeviceIdentity) -> String? {
        guard device.modelIdentifier == frozenModelIdentifier else {
            return "此构建只冻结了 iPhone 14 Pro（iPhone15,2）的 640×480 标定；当前设备为 \(device.modelIdentifier)，实时跑分已阻断。"
        }
        return nil
    }
}
