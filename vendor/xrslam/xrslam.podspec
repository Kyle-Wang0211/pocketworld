Pod::Spec.new do |s|
  s.name             = 'xrslam'
  s.version          = '0.1.0'
  s.summary          = 'Frozen OpenXRLab XRSLAM generic C++ core.'
  s.description      = <<-DESC
    Exact OpenXRLab XRSLAM commit
    4beb1a942f33da9afbfae2d70e2c641cfc2bb675 generic C++ core, with
    XRSLAM_IOS and internal threading disabled on both mobile platforms,
    Ceres 1.14 and OpenCV 4.0.1. The public header is only a
    C-compatible declaration mirror for Swift import. The five-function
    official ABI and algorithm path are unchanged; one lifecycle-only patch
    makes the official Destroy entry release the upstream Detail owner so its
    existing destructor performs the official worker stop/join.
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
