// PwZeroArkitGate.swift —— 「零 ARKit 采集」那条臂的两件原生小事:
//   ① 运行期开关的**第二来源**(`--dart-define` 到不了本工程的 xcconfig 链);
//   ② 相机租约闸:自研臂拿相机前先向 `PwARCameraLease` 登记。
//
// ══ ① 为什么需要第二来源 ═══════════════════════════════════════════════════
// `lib/main.dart:183-192` 的注释是 2026-08-09 的真机实证:**`--dart-define`
// 到不了这个工程的 iOS xcconfig 链**(后端地址因此改成运行期解析)。
// 同一条对 `PW_VIO_POSE_SOURCE` 成立 ⇒ 出货 iOS 包里那个编译期常量**永远**
// 是默认值。对「默认关闭」这条要求这是更强的保证,但也意味着这条臂在真机上
// 物理上打不开。本文件补的就是那条路。
//
// 打开方式(真机,**不需要重新出包**):
//
//     xcrun devicectl device process launch --terminate-existing \
//       --device <UDID> com.kyle.PocketWorld -- -PWVioPoseSource xrslam
//
// iOS 把 `-Key value` 形式的启动参数塞进 `NSArgumentDomain`,所以
// `UserDefaults.standard.string(forKey:)` 直接读得到;同时也从
// `ProcessInfo.processInfo.arguments` 里自己扫一遍作为第二证据 ——
// 两条都走,是因为 NSArgumentDomain 的注册时机在历史上变过,而这条开关
// 「读不到就回落 ARKit」,多读一次不会有坏处。
//
// 🔴 **默认仍然是关的。** 没有这个参数 ⇒ 返回空串 ⇒ Dart 侧按 arkit 走。
// 🔴 本文件**不**提供打开它的 UI,也不写任何持久化 —— `UserDefaults` 只被
//    读,不被写。app 不会自己把自己切到研究臂上。
//
// ══ ② 相机租约 ═════════════════════════════════════════════════════════════
// `PwCameraSlot` 自建 `AVCaptureSession`,**不经过 `PwARCameraLease`**
// (它文件头第 49 行自己写着)。而 ARKit 在会话运行期间独占后置相机:
// 两条一起开 ⇒ `FigCaptureSourceRemote err=-17281`,**两条都废**。
// 之前这只靠「调用方记得别同时开」保证,没有任何运行期闸。
//
// 这里补上:自研臂起相机走 [pw_zero_arkit_camera_start],它先向
// 既有的 `PwARCameraLease`(ARKit 的 `startSession` 用的是同一把锁)
// 申请,拿不到就**失败关闭**并返回 `-100`,而不是去和 ARKit 抢。
//
// 🔴 这也是这条臂的**运行期自证**(09-20 的教训:换臂实验必须能在运行期
//    证明跑的是哪条臂)。`pw_zero_arkit_camera_owner()` 回答
//    「现在相机在谁手里」,不用靠日志猜。
//
// 🔴 本文件**一行都不改** `PwCameraSlot.swift` / `OfficialAetherARKitPlugin
//    .swift` —— 另有两位 agent 正在改那两个文件(照片接口 / 引擎替换)。

import Foundation

/// 租约里自研臂用的 owner 字符串。ARKit 那边用的是它自己的常量,
/// 两者不同 ⇒ 互相拿不到对方持有的锁,这正是想要的。
private let kPwZeroArkitCameraOwner = "pw_zero_arkit_camera"

/// 启动参数 / UserDefaults 的键名。与 Dart 侧的
/// `lib/vio/pose/vio_pose_source_runtime_flag.dart` 必须一字不差。
private let kPwVioPoseSourceKey = "PWVioPoseSource"

// MARK: - ① 运行期开关

/// 把运行期选定的位姿源写进 `out`(C 字符串,含结尾 0)。
///
/// 返回写入的字节数(不含结尾 0);没有设置时写空串并返回 0;
/// `cap` 不够时返回 **−1** 且不写任何东西(**不截断** —— 截断会把
/// `"xrslam"` 变成 `"xrsl"` 然后被当成无法识别的值悄悄回落,
/// 那比明确报错难查得多)。
@_cdecl("pw_vio_pose_source")
public func pw_vio_pose_source(
    _ out: UnsafeMutablePointer<CChar>, _ cap: Int32
) -> Int32 {
    guard cap > 0 else { return -1 }

    var raw = ""
    // (a) NSArgumentDomain:`-PWVioPoseSource xrslam` 直接落这里。
    if let fromDefaults = UserDefaults.standard.string(forKey: kPwVioPoseSourceKey) {
        raw = fromDefaults
    }
    // (b) 自己再扫一遍 argv,作为第二证据。写法与 (a) 取或,不覆盖非空值。
    if raw.isEmpty {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-\(kPwVioPoseSourceKey)"),
           i + 1 < args.count {
            raw = args[i + 1]
        }
    }

    let bytes = Array(raw.utf8)
    // +1 给结尾 0。
    guard bytes.count + 1 <= Int(cap) else { return -1 }
    for (i, b) in bytes.enumerated() { out[i] = CChar(bitPattern: b) }
    out[bytes.count] = 0
    return Int32(bytes.count)
}

// MARK: - ② 相机租约闸

/// 自研臂起相机。参数逐个透传给 `pw_camera_slot_start`。
///
/// 返回值:
///   * `>= 0` / 槽自己的负码 —— 原样来自 `pw_camera_slot_start`;
///   * **`-100`** —— 相机被别人(ARKit)占着,**没有去抢**。
///
/// 🔴 拿不到租约时**不调用**槽的 start:抢一次的代价是两条路一起废
///    (err=-17281),而不是我们这条失败。
@_cdecl("pw_zero_arkit_camera_start")
public func pw_zero_arkit_camera_start(
    _ width: Int32, _ height: Int32, _ fps: Double, _ lensPosition: Double
) -> Int32 {
    guard PwARCameraLease.shared.acquire(owner: kPwZeroArkitCameraOwner) else {
        NSLog("[PwZeroArkitGate] 相机租约拿不到 —— ARKit 还占着。不抢,返回 -100")
        return -100
    }
    let rc = pw_camera_slot_start(width, height, fps, lensPosition)
    if rc < 0 {
        // 起不来就立刻还锁,否则一次失败会把相机永久锁死在我们名下。
        PwARCameraLease.shared.release(owner: kPwZeroArkitCameraOwner)
    }
    return rc
}

/// 停相机并还租约。**幂等** —— 没持有时 `release` 自己是 no-op。
@_cdecl("pw_zero_arkit_camera_stop")
public func pw_zero_arkit_camera_stop() {
    pw_camera_slot_stop()
    PwARCameraLease.shared.release(owner: kPwZeroArkitCameraOwner)
}

/// 运行期自证:相机现在是不是在自研臂手里。
/// `1` = 是;`0` = 不是(空闲或在 ARKit 手里)。
@_cdecl("pw_zero_arkit_camera_owned")
public func pw_zero_arkit_camera_owned() -> Int32 {
    return PwARCameraLease.shared.isOwned(by: kPwZeroArkitCameraOwner) ? 1 : 0
}
