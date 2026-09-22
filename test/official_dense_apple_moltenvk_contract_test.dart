import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'vendor/official_dense';
  const appleRoot = '$root/vulkan_apple';

  test('MoltenVK integration is opt-in and fail closed', () {
    final cmake = File('$root/CMakeLists.txt').readAsStringSync();

    expect(cmake, contains('option(PW_DENSE_ENABLE_APPLE_MOLTENVK'));
    expect(
      cmake,
      matches(RegExp(r'option\(PW_DENSE_ENABLE_APPLE_MOLTENVK[\s\S]*?OFF\)')),
    );
    expect(cmake, contains('PW_DENSE_MOLTENVK_ROOT'));
    expect(cmake, contains('PW_DENSE_ENABLE_VULKAN_RUNTIME=ON'));
    expect(cmake, contains('PW_DENSE_ENABLE_APPLE_MOLTENVK=ON requires Apple'));
    expect(cmake, contains('MoltenVK/MoltenVK.xcframework'));
    expect(cmake, contains('ios-arm64/libMoltenVK.a'));
    expect(
      cmake,
      contains('the fixed official iOS package has no simulator slice'),
    );
    expect(cmake, isNot(contains('ios-arm64_x86_64-simulator/libMoltenVK.a')));
    expect(cmake, contains('pw_official_dense_moltenvk_link_smoke'));
    expect(cmake, contains('clang++ driver links libc++ exactly'));
    expect(cmake, isNot(contains('"-lc++"')));
    expect(cmake.toLowerCase(), isNot(contains('fetchcontent')));
    expect(cmake.toLowerCase(), isNot(contains('download')));
  });

  test('Apple loader strongly references the MoltenVK Vulkan entry point', () {
    final header = File('$appleRoot/moltenvk_loader.h').readAsStringSync();
    final source = File('$appleRoot/moltenvk_loader.cc').readAsStringSync();
    final smoke = File('$appleRoot/moltenvk_link_smoke.cc').readAsStringSync();

    expect(header, contains('MoltenVkExternalLoader() noexcept'));
    expect(header, contains('../vulkan_host/vulkan_host.h'));
    expect(source, contains('&vkGetInstanceProcAddr'));
    expect(source, contains('MoltenVkExternalLoader() noexcept'));
    expect(smoke, contains('MoltenVkExternalLoader()'));
    expect(smoke, contains('get_instance_proc_addr'));
    expect(
      Directory(appleRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.swift')),
      isEmpty,
    );
  });

  test('missing fixed MoltenVK package is rejected during configure', () {
    final temp = Directory.systemTemp.createTempSync('pw-moltenvk-missing-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final configure = Process.runSync('cmake', <String>[
      '-S',
      root,
      '-B',
      temp.path,
      '-DBUILD_TESTING=OFF',
      '-DPW_DENSE_ENABLE_VULKAN_RUNTIME=ON',
      '-DPW_DENSE_ENABLE_APPLE_MOLTENVK=ON',
      '-DPW_DENSE_MOLTENVK_ROOT=${temp.path}/missing',
    ]);
    expect(configure.exitCode, isNot(0));
    expect(
      '${configure.stdout}\n${configure.stderr}',
      contains('PW_DENSE_MOLTENVK_ROOT'),
    );
  });

  test('Apple loader is strict C++17 with no Objective-C dependency', () {
    final vulkanHeaders =
        <String>[
          if (Platform.environment['VULKAN_SDK'] case final String value)
            '$value/include',
          '/opt/homebrew/include',
          '/usr/local/include',
          '/opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/'
              'darwin-x86_64/sysroot/usr/include',
        ].map(Directory.new).where((directory) {
          return File('${directory.path}/vulkan/vulkan.h').existsSync();
        }).firstOrNull;
    expect(vulkanHeaders, isNotNull, reason: 'Vulkan headers are required');

    final syntax = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Wpedantic',
      '-Wconversion',
      '-Wsign-conversion',
      '-Werror',
      '-idirafter',
      vulkanHeaders!.path,
      '-I$root',
      '-fsyntax-only',
      '$appleRoot/moltenvk_loader.cc',
      '$appleRoot/moltenvk_link_smoke.cc',
    ]);
    expect(syntax.exitCode, 0, reason: '${syntax.stdout}\n${syntax.stderr}');
  });
}
