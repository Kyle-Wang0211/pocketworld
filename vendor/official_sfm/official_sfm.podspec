Pod::Spec.new do |s|
  s.name             = 'official_sfm'
  s.version          = '1.0.0'
  s.summary          = 'Independent native SfM runtime for Pocketworld official-route experiments.'
  s.description      = <<-DESC
    A physically independent dynamic XCFramework that initially mirrors the
    production streaming SfM implementation behind a separate pwofficial_* ABI.
    Its internal C/C++ symbols are hidden and its runtime configuration reads
    only OFFICIAL_AETHER_* keys.
  DESC
  s.homepage         = 'https://github.com/Kyle-Wang0211/Pocketworld'
  s.license          = { :type => 'Proprietary', :text => 'See repository LICENSE and third-party notices.' }
  s.author           = { 'Kyle Wang' => 'wkd20040211@gmail.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '14.0'
  s.vendored_frameworks = 'Frameworks/PWOfficialSfm.xcframework'
  s.preserve_paths   = [
    'Frameworks/PWOfficialSfm.xcframework',
    'include/**/*',
    'libs/**/*',
    'scripts/**/*',
    '*_abi_symbols.txt',
  ]
  s.frameworks = 'Foundation', 'Metal', 'CoreVideo', 'IOSurface', 'QuartzCore', 'Accelerate', 'CoreGraphics', 'ImageIO'
  s.libraries  = 'c++', 'z', 'sqlite3'
end
