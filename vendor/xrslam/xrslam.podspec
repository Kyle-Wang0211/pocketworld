Pod::Spec.new do |s|
  s.name             = 'xrslam'
  s.version          = '0.1.0'
  s.summary          = 'XRSLAM (OpenXRLab / RD-VIO) C ABI — pocketworld fork.'
  s.description      = <<-DESC
    XRSLAM 的 pocketworld fork(分支 pw/vio,起点 manorajesh d052dc3)。

    与上游的关键差异,改了都是有理由的:
      • C 头回退成**纯 C11**(上游在 extern "C" 里塞 std::vector),ffigen 才能吃
      • 去掉 exit(-1),改错误码 + try/catch 兜 extern "C" 边界(CERT ERR50/59-CPP)
      • XRSLAM_IOS 一个宏拆成三个正交开关 —— 上游用它同时控制线程模型、
        低延迟位姿链、关键帧策略,导致 iOS 与 Android **跑结构性不同的算法**
      • 符号裁剪:导出面从 6552 收到 18(全是 XRSLAM*),operator new/delete 与
        __cxa_throw 不再泄到全局(否则 Flutter 进程里会被符号插入打穿 try/catch)
      • ACCELERATESPARSE 强制 OFF —— Ceres 在 Apple 平台会自动打开它,
        而 Android 没有 Accelerate ⇒ 两端走不同稀疏求解器 ⇒ 数值不同
      • -ffp-contract=off 两端统一

    ⚠️ 本 .a 自包含 ceres/yaml-cpp/spdlog(已实测 ceres 真缺符号 = 0),
       但 **OpenCV 单独链** —— 用的是自编 5.0.0(minos 14.0),不是那份
       Target iOS 9.0 + -fembed-bitcode 的旧 4.11 包。
  DESC
  s.homepage         = 'https://github.com/openxrlab/xrslam'
  s.license          = { :type => 'Apache-2.0', :text => 'See LICENSE' }
  s.author           = { 'Kyle Wang' => 'wkd20040211@gmail.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '14.0'

  s.source_files        = 'include/XRSLAM.h'
  s.public_header_files = 'include/XRSLAM.h'
  s.preserve_paths      = 'libs/**/*', 'include/**/*'

  s.libraries = 'c++', 'z'

  s.pod_target_xcconfig = {
    'VALID_ARCHS[sdk=iphoneos*]' => 'arm64',
  }

  # ⚠️ **不要**在这里设 OTHER_LDFLAGS[sdk=iphoneos*]。
  #   实测:两个 pod 同时设它时,CocoaPods 把它当"单值设置",发现冲突就**整槽丢弃**
  #   —— 加上 xrslam 之后,aether3d_ffi 的 -force_load 与整个 -Wl,-u 列表在设备
  #   构建里全部消失(去掉 xrslam 就恢复,已做对照)。那不会编译报错,只会让符号被
  #   dead-strip,表现成运行时找不到函数。
  #   xrslam 的链接参数改在 ios/Podfile 的 post_install 里追加到生成的 xcconfig,
  #   与 onnxruntime 走同一条路(见那里的注释:CocoaPods 写 xcconfig 早于 post_install,
  #   所以必须改文本而不是 build_settings)。
  s.user_target_xcconfig = {
    'VALID_ARCHS[sdk=iphoneos*]' => 'arm64',
  }
end
