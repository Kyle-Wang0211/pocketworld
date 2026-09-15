Pod::Spec.new do |s|
  s.name             = 'pw_dense'
  s.version          = '1.0.0'
  s.summary          = 'On-device dense point cloud (CasDiffMVS on ORT-WebGPU + official fusion) behind the pwdense_* ABI.'
  s.description      = <<-DESC
    PWDense.xcframework: the gated dense C++ (aether_cpp/src/dense) linked with the product's OpenCV 4.0.1
    archive, the pinned libjpeg-turbo, and ONNX Runtime 1.29.0 (self-built, WebGPU EP) re-homed as
    PWOnnxRuntime.xcframework. Dart opens PWDense by path (like PWOfficialSfm); nothing links it statically.
    Rebuild with scripts/build_xcframeworks.sh (sources in Aether3D-cross/aether_cpp/src/dense).
  DESC
  s.homepage         = 'https://github.com/Kyle-Wang0211/Pocketworld'
  s.license          = { :type => 'Proprietary', :text => 'See repository LICENSE and third-party notices.' }
  s.author           = { 'Kyle Wang' => 'wkd20040211@gmail.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.vendored_frameworks = ['Frameworks/PWDense.xcframework', 'Frameworks/PWOnnxRuntime.xcframework']
  s.preserve_paths   = ['Frameworks/**/*', 'include/**/*', 'scripts/**/*', 'pwdense_abi_symbols.txt']
  s.frameworks = 'Foundation', 'Accelerate', 'Metal', 'QuartzCore'
  s.libraries  = 'c++', 'z'
end
