# pw_hevc — 采集期 HEVC 归档的原生层(纯 C,零 Swift)
# 单一真源在 ../src/;Classes/ 只是 umbrella include(Flutter ffi 插件官方模式)。
Pod::Spec.new do |s|
  s.name             = 'pw_hevc'
  s.version          = '0.1.0'
  s.summary          = 'PocketWorld capture-time HEVC archive native layer (pure C).'
  s.description      = 'VideoToolbox sync adapters for Dart FFI. No Swift, no ObjC.'
  s.homepage         = 'https://pocketworld.invalid'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'PocketWorld' => 'dev@pocketworld.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'ImageIO', 'CoreGraphics', 'CoreFoundation'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # Release 的 -dead_strip 会剥掉只经 DynamicLibrary.process()/dlsym 访问的
  # 符号(aether_ffi 的 finalize_async 事故同款)。显式标记为 needed。
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '-Wl,-u,_pw_vt_create -Wl,-u,_pw_vt_encode_nv12 -Wl,-u,_pw_vt_encode_cvpb -Wl,-u,_pw_vt_flush -Wl,-u,_pw_vt_free -Wl,-u,_pw_vt_destroy -Wl,-u,_pw_vt_dec_create -Wl,-u,_pw_vt_dec_decode -Wl,-u,_pw_vt_dec_destroy -Wl,-u,_pw_jpeg_to_bgra_cvpb -Wl,-u,_pw_nv12_to_jpeg_file -Wl,-u,_pw_cvpb_release' }
end
