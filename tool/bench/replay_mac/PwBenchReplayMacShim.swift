// Mac 等价核对专用(不进任何 App):让 Dart 测试在**本进程第一次读开关之前**
// 把启动参数写进 NSArgumentDomain —— 与 iOS 上 `devicectl ... -- -PWPerFrameIntrinsics off`
// 落到的是同一个域(PwXrslamLive.swift:146 `UserDefaults.standard.string(forKey:)` 读的就是它)。
// flutter_tester 进程的 argv 我们管不了,这是唯一不改产品代码的注入点。
import Foundation

@_cdecl("pw_bench_replay_mac_set_argument")
public func pw_bench_replay_mac_set_argument(_ key: UnsafePointer<CChar>,
                                             _ value: UnsafePointer<CChar>) {
    var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    domain[String(cString: key)] = String(cString: value)
    UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
}
