// lidar_subset_export —— 在 Mac 上跑 PwBenchLidarRecordingWriter.exportRulerSubset(与手机上同一份代码)。
// 🔴 bench-only ruler。用法:lidar_subset_export <run-目录> <最小间隔秒>
import Foundation

let argv = CommandLine.arguments
guard argv.count >= 3, let spacing = Double(argv[2]) else {
    FileHandle.standardError.write(Data("usage: lidar_subset_export <recording_dir> <min_spacing_s>\n".utf8))
    exit(2)
}
do {
    let s = try PwBenchLidarRecordingWriter.exportRulerSubset(
        recording: URL(fileURLWithPath: argv[1], isDirectory: true), minSpacingSeconds: spacing)
    let d = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: d, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("🔴 \(error.localizedDescription)\n".utf8))
    exit(1)
}
