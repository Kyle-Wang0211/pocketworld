// replay_events_dump_main.swift —— [xr-recon-chain 2026-09-25] 回放装载器 → 「推送序列」规范转储 + SHA-256。
//
// 用途:证明装载器 D11(新 IMU 格式)改动后,**旧格式录制**喂进引擎的东西逐位不变 —— 同一份录制,用改前 / 改后
// 两版 PwBenchReplayRecording.swift 各编一次本工具,比输出的 sha。规范序列 = PwBenchReplay.swift 投递处对每个事件
// 实际做的推送(时间换算 Double(t_ns)·1e-9 与那里逐字相同):
//   .imu   → 一行 G(陀螺)+ 一行 A(加计),同一个 t(pushReplayImu:先陀螺后加计)
//   .gyro  → 一行 G;.accel → 一行 A(pushReplayGyro / pushReplayAccel)
//   .camera→ 一行 C:t、录制帧号、字节区间、曝光、逐帧 K(onCameraFrame 的全部输入)
// 所有浮点按 IEEE-754 位模式十六进制写出(逐位比)。只读录制,不读 frames.bin 的像素(字节区间已唯一确定像素)。
// 编译开关 PW_SPLIT_IMU:新装载器有 .gyro / .accel 两个事件,旧装载器没有(同一份源码编两版)。
import CryptoKit
import Foundation

func hx(_ v: Double) -> String { String(v.bitPattern, radix: 16) }

let args = CommandLine.arguments.dropFirst()
for path in args {
    let url = URL(fileURLWithPath: path).appendingPathComponent(DeviceRecordingManifest.fileName)
    var opt = DeviceRecordingLoadOptions()
    opt.allowLossy = true
    do {
        let ds = try DeviceRecordingLoader(options: opt).load(manifestURL: url)
        var out = ""
        out.reserveCapacity(ds.events.count * 96)
        var g = 0, a = 0, c = 0
        for e in ds.events {
            switch e {
            case .imu(let s):
                let t = Double(s.timestampNanoseconds) * 1e-9
                let w = s.gyroscopeRadiansPerSecond, f = s.accelerationMetersPerSecondSquared
                out += "G \(hx(t)) \(hx(w.x)) \(hx(w.y)) \(hx(w.z))\n"
                out += "A \(hx(t)) \(hx(f.x)) \(hx(f.y)) \(hx(f.z))\n"
                g += 1; a += 1
#if PW_SPLIT_IMU
            case .gyro(let s):
                let t = Double(s.timestampNanoseconds) * 1e-9
                out += "G \(hx(t)) \(hx(s.value.x)) \(hx(s.value.y)) \(hx(s.value.z))\n"
                g += 1
            case .accel(let s):
                let t = Double(s.timestampNanoseconds) * 1e-9
                out += "A \(hx(t)) \(hx(s.value.x)) \(hx(s.value.y)) \(hx(s.value.z))\n"
                a += 1
#endif
            case .camera(let f):
                let t = Double(f.timestampNanoseconds) * 1e-9
                let k = f.intrinsicsFxFyCxCy.map { $0.map(hx).joined(separator: ",") } ?? "nil"
                out += "C \(hx(t)) \(f.frameIndex) \(f.byteRange.lowerBound)-\(f.byteRange.upperBound) "
                    + "\(f.exposureSeconds.map(hx) ?? "nil") \(k)\n"
                c += 1
            }
        }
        let sha = SHA256.hash(data: Data(out.utf8)).map { String(format: "%02x", $0) }.joined()
        let r = ds.report
        print("\(URL(fileURLWithPath: path).lastPathComponent) sha256=\(sha) G=\(g) A=\(a) C=\(c) "
              + "leading_dropped=\(r.leadingCameraFramesWithoutImuDropped) ties=\(r.cameraImuTimestampTies)")
    } catch {
        print("\(path) ERROR \(error)")
    }
}
