cmake_minimum_required(VERSION 3.22)

project(PocketWorldOfficialDense VERSION 0.1.0 LANGUAGES CXX)

include(CTest)
include(GNUInstallDirs)

option(PW_DENSE_ENABLE_VULKAN_RUNTIME
       "Compile the Vulkan runtime instead of its fail-closed host stub" OFF)
option(PW_DENSE_ENABLE_APPLE_MOLTENVK
       "Link the fixed official MoltenVK iOS static XCFramework" OFF)
option(PW_DENSE_ENABLE_APPLE_DEVICE_PROBE
       "Build the isolated unsigned iOS Vulkan diagnostic App" OFF)
option(PW_DENSE_ENABLE_APPLE_HOST_PROBE
       "Build the isolated macOS Vulkan frozen-scene diagnostic" OFF)
option(PW_DENSE_ENABLE_OFFICIAL_FUSION
       "Link the exact COLMAP 4.1.1 StereoFusion implementation" OFF)
set(PW_DENSE_MOLTENVK_ROOT "" CACHE PATH
    "Root of the fixed official MoltenVK iOS release archive")
set(PW_DENSE_FROZEN_SCENE_ROOT "" CACHE PATH
    "Read-only frozen COLMAP fixture directory for the benchmark App")

if(PW_DENSE_ENABLE_APPLE_DEVICE_PROBE AND
   NOT PW_DENSE_ENABLE_APPLE_MOLTENVK)
  message(FATAL_ERROR
    "PW_DENSE_ENABLE_APPLE_DEVICE_PROBE=ON requires "
    "PW_DENSE_ENABLE_APPLE_MOLTENVK=ON")
endif()
if(PW_DENSE_ENABLE_APPLE_HOST_PROBE AND
   NOT PW_DENSE_ENABLE_APPLE_MOLTENVK)
  message(FATAL_ERROR
    "PW_DENSE_ENABLE_APPLE_HOST_PROBE=ON requires "
    "PW_DENSE_ENABLE_APPLE_MOLTENVK=ON")
endif()

if(PW_DENSE_ENABLE_APPLE_MOLTENVK)
  if(NOT APPLE)
    message(FATAL_ERROR
      "PW_DENSE_ENABLE_APPLE_MOLTENVK=ON requires Apple")
  endif()
  if(NOT PW_DENSE_ENABLE_VULKAN_RUNTIME)
    message(FATAL_ERROR
      "PW_DENSE_ENABLE_APPLE_MOLTENVK=ON requires "
      "PW_DENSE_ENABLE_VULKAN_RUNTIME=ON")
  endif()

  # Khronos ships the iOS and macOS archives with different directory layouts.
  # Select the official static XCFramework in place; do not repack it.
  set(_pw_dense_moltenvk_include_root
      "${PW_DENSE_MOLTENVK_ROOT}/MoltenVK/include")
  set(_pw_dense_moltenvk_xcframework
      "${PW_DENSE_MOLTENVK_ROOT}/MoltenVK/MoltenVK.xcframework")
  if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND
     EXISTS "${PW_DENSE_MOLTENVK_ROOT}/MoltenVK/MoltenVK/static/MoltenVK.xcframework/Info.plist")
    set(_pw_dense_moltenvk_include_root
        "${PW_DENSE_MOLTENVK_ROOT}/MoltenVK/MoltenVK/include")
    set(_pw_dense_moltenvk_xcframework
        "${PW_DENSE_MOLTENVK_ROOT}/MoltenVK/MoltenVK/static/MoltenVK.xcframework")
  endif()
  if(NOT EXISTS "${_pw_dense_moltenvk_xcframework}/Info.plist")
    message(FATAL_ERROR
      "PW_DENSE_MOLTENVK_ROOT must contain the fixed official "
      "MoltenVK/MoltenVK.xcframework package")
  endif()

  if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND
     NOT CMAKE_OSX_SYSROOT MATCHES "iphonesimulator")
    set(_pw_dense_moltenvk_library
        "${_pw_dense_moltenvk_xcframework}/ios-arm64/libMoltenVK.a")
  elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(_pw_dense_moltenvk_library
        "${_pw_dense_moltenvk_xcframework}/macos-arm64_x86_64/libMoltenVK.a")
  else()
    message(FATAL_ERROR
      "PW_DENSE_ENABLE_APPLE_MOLTENVK=ON requires physical iPhoneOS or macOS")
  endif()

  get_filename_component(_pw_dense_moltenvk_slice
                         "${_pw_dense_moltenvk_library}" DIRECTORY)
  set(_pw_dense_moltenvk_headers "${_pw_dense_moltenvk_include_root}")
  if(NOT EXISTS "${_pw_dense_moltenvk_library}" OR
     NOT EXISTS "${_pw_dense_moltenvk_headers}/vulkan/vulkan.h")
    message(FATAL_ERROR
      "PW_DENSE_MOLTENVK_ROOT is missing the selected static XCFramework "
      "slice or Vulkan headers")
  endif()

  # MoltenVK is the Apple platform Vulkan SDK for this opt-in closure.
  set(PW_DENSE_VULKAN_INCLUDE_DIR "${_pw_dense_moltenvk_headers}"
      CACHE PATH "Directory containing vulkan/vulkan.h from the platform SDK"
      FORCE)
endif()

# This flag is intentionally immutable until the frozen CUDA parity gate passes.
# A successful portable build is not evidence that the dense backend is ready.
set(PW_DENSE_OVERALL_READY FALSE CACHE INTERNAL
    "overall_ready from the official dense parity gate" FORCE)

set(_pw_dense_sources
    workspace_io/workspace_io.cc
    patch_match_controller/patch_match_controller.cc
    file_transaction/anchored_transaction.cc
    file_transaction/anchored_transaction_c.cc
    vulkan_host/dispatch_plan.cc
    vulkan_host/vulkan_host.cc
    vulkan_resource_arena/resource_arena_plan.cc
    ffi/src/pwofficial_dense_c.cc
    ffi/src/backend_unavailable.cc)

if(PW_DENSE_ENABLE_VULKAN_RUNTIME)
  list(APPEND _pw_dense_sources
       vulkan_runtime/vulkan_runtime.cc
       vulkan_shader_bundle/shader_bundle.cc
       vulkan_resource_arena/resource_arena.cc
       vulkan_batch_executor/batch_executor.cc)
endif()

if(PW_DENSE_ENABLE_APPLE_MOLTENVK)
  list(APPEND _pw_dense_sources
       vulkan_apple/moltenvk_loader.cc
       vulkan_apple/frozen_scene_loader.cc
       vulkan_apple/diagnostic_map_export.cc)
endif()

# The bridge is useful in the portable library even when official fusion is
# disabled: in that configuration it returns kUnavailable and publishes no PLY.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/fusion_bridge/stereo_fusion_bridge.cc")
  list(APPEND _pw_dense_sources
       fusion_bridge/stereo_fusion_bridge.cc)
endif()

add_library(pw_official_dense_portable STATIC ${_pw_dense_sources})
add_library(PocketWorld::OfficialDense ALIAS pw_official_dense_portable)

if(PW_DENSE_ENABLE_APPLE_DEVICE_PROBE OR
   PW_DENSE_ENABLE_APPLE_HOST_PROBE)
  target_compile_definitions(
    pw_official_dense_portable
    PRIVATE PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC=1)
endif()

target_compile_features(pw_official_dense_portable PUBLIC cxx_std_17)
target_include_directories(
  pw_official_dense_portable
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/ffi/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
set_target_properties(
  pw_official_dense_portable
  PROPERTIES
    EXPORT_NAME OfficialDense
    POSITION_INDEPENDENT_CODE ON)

if(PW_DENSE_ENABLE_VULKAN_RUNTIME)
  set(PW_DENSE_VULKAN_INCLUDE_DIR "" CACHE PATH
      "Directory containing vulkan/vulkan.h from the platform SDK")
  if(NOT PW_DENSE_VULKAN_INCLUDE_DIR)
    find_path(_pw_dense_vulkan_include_dir vulkan/vulkan.h)
    if(_pw_dense_vulkan_include_dir)
      set(PW_DENSE_VULKAN_INCLUDE_DIR "${_pw_dense_vulkan_include_dir}")
    endif()
  endif()
  if(NOT EXISTS "${PW_DENSE_VULKAN_INCLUDE_DIR}/vulkan/vulkan.h")
    message(FATAL_ERROR
      "PW_DENSE_ENABLE_VULKAN_RUNTIME=ON requires platform Vulkan headers")
  endif()
  target_include_directories(
    pw_official_dense_portable PRIVATE "${PW_DENSE_VULKAN_INCLUDE_DIR}")

  # Only Android calls the platform Vulkan loader directly. Apple and Harmony
  # inject vkGetInstanceProcAddr through the public zero-Swift C++ boundary.
  if(ANDROID)
    find_library(_pw_dense_vulkan_library NAMES vulkan)
    if(NOT _pw_dense_vulkan_library)
      message(FATAL_ERROR
        "PW_DENSE_ENABLE_VULKAN_RUNTIME=ON requires Android libvulkan")
    endif()
    target_link_libraries(
      pw_official_dense_portable PRIVATE "${_pw_dense_vulkan_library}")
  endif()

  if(PW_DENSE_ENABLE_APPLE_MOLTENVK)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
      set(_pw_dense_apple_ui_framework UIKit)
    else()
      set(_pw_dense_apple_ui_framework AppKit)
    endif()
    foreach(_pw_dense_framework
            Metal Foundation QuartzCore CoreGraphics IOSurface
            ${_pw_dense_apple_ui_framework})
      find_library(_pw_dense_${_pw_dense_framework}_framework
                   NAMES ${_pw_dense_framework})
      if(NOT _pw_dense_${_pw_dense_framework}_framework)
        message(FATAL_ERROR
          "MoltenVK requires Apple framework ${_pw_dense_framework}")
      endif()
      list(APPEND _pw_dense_moltenvk_frameworks
           "${_pw_dense_${_pw_dense_framework}_framework}")
    endforeach()
    if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
      find_library(_pw_dense_IOKit_framework NAMES IOKit)
      if(NOT _pw_dense_IOKit_framework)
        message(FATAL_ERROR "MoltenVK on macOS requires IOKit")
      endif()
      list(APPEND _pw_dense_moltenvk_frameworks
           "${_pw_dense_IOKit_framework}")
    endif()
    target_link_libraries(
      pw_official_dense_portable
      PRIVATE
        "${_pw_dense_moltenvk_library}"
        ${_pw_dense_moltenvk_frameworks})
    # This is a C++ target, so the Apple clang++ driver links libc++ exactly
    # once. Adding a manual -lc++ produces a duplicate-library warning.

    add_executable(
      pw_official_dense_moltenvk_link_smoke EXCLUDE_FROM_ALL
      vulkan_apple/moltenvk_link_smoke.cc)
    target_compile_features(
      pw_official_dense_moltenvk_link_smoke PRIVATE cxx_std_17)
    target_link_libraries(
      pw_official_dense_moltenvk_link_smoke
      PRIVATE PocketWorld::OfficialDense)

    if(PW_DENSE_ENABLE_APPLE_DEVICE_PROBE)
      if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR
          "PW_DENSE_ENABLE_APPLE_DEVICE_PROBE=ON requires iPhoneOS")
      endif()
      enable_language(OBJCXX)
      find_library(_pw_dense_BackgroundTasks_framework NAMES BackgroundTasks)
      if(NOT _pw_dense_BackgroundTasks_framework)
        message(FATAL_ERROR
          "iOS continued GPU execution requires BackgroundTasks.framework")
      endif()
      add_executable(
        pw_official_dense_moltenvk_device_probe MACOSX_BUNDLE EXCLUDE_FROM_ALL
        vulkan_apple/device_probe_main.cc
        vulkan_apple/device_probe_uikit_host.mm
        vulkan_apple/device_probe.cc
        vulkan_apple/patch_match_sequence_probe.cc
        vulkan_apple/frozen_scene_probe.cc)
      target_compile_features(
        pw_official_dense_moltenvk_device_probe PRIVATE cxx_std_17)
      target_compile_definitions(
        pw_official_dense_moltenvk_device_probe
        PRIVATE PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC=1)
      target_include_directories(
        pw_official_dense_moltenvk_device_probe
        PRIVATE "${PW_DENSE_VULKAN_INCLUDE_DIR}")
      target_link_libraries(
        pw_official_dense_moltenvk_device_probe
        PRIVATE
          PocketWorld::OfficialDense
          "${_pw_dense_BackgroundTasks_framework}")
      set_target_properties(
        pw_official_dense_moltenvk_device_probe
        PROPERTIES
          MACOSX_BUNDLE_BUNDLE_NAME "PocketWorld Dense Probe"
          MACOSX_BUNDLE_GUI_IDENTIFIER "com.kyle.PocketWorld.DenseProbe"
          MACOSX_BUNDLE_INFO_PLIST
            "${CMAKE_CURRENT_SOURCE_DIR}/vulkan_apple/device_probe_info.plist.in"
          XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
            "com.kyle.PocketWorld.DenseProbe"
          XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
          XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO")
      if(PW_DENSE_FROZEN_SCENE_ROOT)
        if(NOT EXISTS "${PW_DENSE_FROZEN_SCENE_ROOT}/b28_selection.packet" OR
           NOT EXISTS "${PW_DENSE_FROZEN_SCENE_ROOT}/gray_pgm")
          message(FATAL_ERROR
            "PW_DENSE_FROZEN_SCENE_ROOT must contain b28_selection.packet "
            "and gray_pgm/")
        endif()
        target_compile_definitions(
          pw_official_dense_moltenvk_device_probe
          PRIVATE PW_DENSE_FROZEN_SCENE_BUNDLE=1)
        add_custom_command(
          TARGET pw_official_dense_moltenvk_device_probe POST_BUILD
          COMMAND "${CMAKE_COMMAND}" -E copy_directory
                  "${PW_DENSE_FROZEN_SCENE_ROOT}"
                  "$<TARGET_FILE_DIR:pw_official_dense_moltenvk_device_probe>/FrozenB28"
          VERBATIM)
      endif()
    endif()

    if(PW_DENSE_ENABLE_APPLE_HOST_PROBE)
      if(NOT CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        message(FATAL_ERROR
          "PW_DENSE_ENABLE_APPLE_HOST_PROBE=ON requires macOS")
      endif()
      add_executable(
        pw_official_dense_moltenvk_host_probe EXCLUDE_FROM_ALL
        vulkan_apple/device_probe_cli_host.cc
        vulkan_apple/device_probe_main.cc
        vulkan_apple/device_probe.cc
        vulkan_apple/patch_match_sequence_probe.cc
        vulkan_apple/frozen_scene_probe.cc)
      target_compile_features(
        pw_official_dense_moltenvk_host_probe PRIVATE cxx_std_17)
      target_compile_definitions(
        pw_official_dense_moltenvk_host_probe
        PRIVATE PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC=1)
      target_include_directories(
        pw_official_dense_moltenvk_host_probe
        PRIVATE "${PW_DENSE_VULKAN_INCLUDE_DIR}")
      target_link_libraries(
        pw_official_dense_moltenvk_host_probe
        PRIVATE PocketWorld::OfficialDense)
      if(PW_DENSE_FROZEN_SCENE_ROOT)
        if(NOT EXISTS "${PW_DENSE_FROZEN_SCENE_ROOT}/b28_selection.packet" OR
           NOT EXISTS "${PW_DENSE_FROZEN_SCENE_ROOT}/gray_pgm")
          message(FATAL_ERROR
            "PW_DENSE_FROZEN_SCENE_ROOT must contain b28_selection.packet "
            "and gray_pgm/")
        endif()
        target_compile_definitions(
          pw_official_dense_moltenvk_host_probe
          PRIVATE PW_DENSE_FROZEN_SCENE_BUNDLE=1)
        add_custom_command(
          TARGET pw_official_dense_moltenvk_host_probe POST_BUILD
          COMMAND "${CMAKE_COMMAND}" -E copy_directory
                  "${PW_DENSE_FROZEN_SCENE_ROOT}"
                  "$<TARGET_FILE_DIR:pw_official_dense_moltenvk_host_probe>/FrozenB28"
          VERBATIM)
      endif()
    endif()
  endif()
else()
  target_compile_definitions(
    pw_official_dense_portable PRIVATE PW_OFFICIAL_DENSE_VULKAN_STUB=1)
endif()

if(PW_DENSE_ENABLE_OFFICIAL_FUSION)
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/fusion_bridge/stereo_fusion_bridge.cc")
    message(FATAL_ERROR
      "PW_DENSE_ENABLE_OFFICIAL_FUSION=ON requires the official fusion bridge")
  endif()

  # Compile only the checked-in official CPU StereoFusion closure. Do not use
  # COLMAP's top-level package/target: it would make sparse features, GUI,
  # CUDA, meshing, and their transitive dependencies part of this build graph.
  # The child smoke target is redundant here because the parent tests link the
  # final portable archive; keep the standalone smoke available to direct
  # official_cpu_mvs builds.
  set(PW_OFFICIAL_CPU_MVS_BUILD_SMOKE OFF)
  set(PW_COLMAP_SOURCE_DIR
      "${CMAKE_CURRENT_SOURCE_DIR}/third_party/colmap-4.1.1")
  if(DEFINED CMAKE_FIND_PACKAGE_TARGETS_GLOBAL)
    set(_pw_dense_had_find_package_targets_global TRUE)
    set(_pw_dense_saved_find_package_targets_global
        "${CMAKE_FIND_PACKAGE_TARGETS_GLOBAL}")
  else()
    set(_pw_dense_had_find_package_targets_global FALSE)
  endif()
  # The child resolves the exact narrow closure dependencies. Promote those
  # imported targets so this parent static target can preserve them in its
  # LINK_ONLY build/install interface.
  set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL TRUE)
  add_subdirectory(official_cpu_mvs
                   "${CMAKE_CURRENT_BINARY_DIR}/official_cpu_mvs"
                   EXCLUDE_FROM_ALL)
  if(_pw_dense_had_find_package_targets_global)
    set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL
        "${_pw_dense_saved_find_package_targets_global}")
  else()
    unset(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL)
  endif()
  if(NOT TARGET pw_official_cpu_mvs_objects)
    message(FATAL_ERROR
      "PW_DENSE_ENABLE_OFFICIAL_FUSION=ON requires the in-tree official CPU "
      "StereoFusion object closure")
  endif()

  # Put the frozen upstream objects inside the same installed static archive.
  # Linking the child static target would leave a non-exported target in the
  # install interface and would not merge its objects into this archive.
  set_target_properties(
    pw_official_cpu_mvs_objects PROPERTIES POSITION_INDEPENDENT_CODE ON)
  target_sources(
    pw_official_dense_portable
    PRIVATE $<TARGET_OBJECTS:pw_official_cpu_mvs_objects>)
  target_include_directories(
    pw_official_dense_portable PRIVATE "${PW_COLMAP_SOURCE_DIR}/src")
  target_compile_definitions(
    pw_official_dense_portable
    PRIVATE
      PW_OFFICIAL_DENSE_WITH_COLMAP_4_1_1=1
      GLOG_USE_GLOG_EXPORT
      GLOG_NO_ABBREVIATED_SEVERITIES
      GLOG_VERSION_MAJOR=0
      GLOG_VERSION_MINOR=7)
  # These imported dependencies remain in the static target's LINK_ONLY
  # install interface, so consumers resolve the same target-ABI packages. No
  # internal official_cpu_mvs target leaks into the exported target set.
  target_link_libraries(
    pw_official_dense_portable
    PRIVATE
      Eigen3::Eigen
      Boost::headers
      glog::glog
      OpenImageIO::OpenImageIO)

  add_executable(
    pw_official_dense_stereo_fusion
    tools/stereo_fusion_cli.cc)
  target_compile_features(
    pw_official_dense_stereo_fusion PRIVATE cxx_std_17)
  target_link_libraries(
    pw_official_dense_stereo_fusion
    PRIVATE PocketWorld::OfficialDense)

  add_executable(
    pw_official_dense_selection_export
    tools/colmap_selection_export.cc)
  target_compile_features(
    pw_official_dense_selection_export PRIVATE cxx_std_17)
  target_include_directories(
    pw_official_dense_selection_export
    PRIVATE "${PW_COLMAP_SOURCE_DIR}/src")
  target_link_libraries(
    pw_official_dense_selection_export
    PRIVATE PocketWorld::OfficialDense)
endif()

# Shader translation is explicit and never part of the default portable build.
# build_gate.py writes SPIR-V and its manifest below CMAKE_CURRENT_BINARY_DIR.
find_package(Python3 COMPONENTS Interpreter REQUIRED)
set(_pw_dense_shader_output
    "${CMAKE_CURRENT_BINARY_DIR}/generated/shaders")
set(_pw_dense_shader_manifest "${_pw_dense_shader_output}/manifest.json")
file(GLOB_RECURSE _pw_dense_shader_inputs CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/*.comp"
     "${CMAKE_CURRENT_SOURCE_DIR}/*.glsl")
add_custom_command(
  OUTPUT "${_pw_dense_shader_manifest}"
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_pw_dense_shader_output}"
  COMMAND "${Python3_EXECUTABLE}"
          "${CMAKE_CURRENT_SOURCE_DIR}/build/build_gate.py"
          --output "${_pw_dense_shader_output}"
  COMMAND "${CMAKE_COMMAND}"
          "-DMANIFEST_PATH=${_pw_dense_shader_manifest}"
          -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifyFailClosedManifest.cmake"
  DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/build/build_gate.py"
    "${CMAKE_CURRENT_SOURCE_DIR}/upstream_import/colmap_4_1_1_manifest.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifyFailClosedManifest.cmake"
    ${_pw_dense_shader_inputs}
  VERBATIM
  COMMENT "Compile and validate fail-closed official dense shaders")
add_custom_target(pw_official_dense_shaders
                  DEPENDS "${_pw_dense_shader_manifest}")

if(BUILD_TESTING AND NOT CMAKE_CROSSCOMPILING)
  set(_pw_dense_frozen_abi_symbols
      pwofficial_dense_version
      pwofficial_dense_last_error
      pwofficial_dense_default_options
      pwofficial_dense_is_available
      pwofficial_dense_run
      pwofficial_dense_cancel)
  file(STRINGS
       "${CMAKE_CURRENT_SOURCE_DIR}/ffi/pwofficial_dense_abi_symbols.txt"
       _pw_dense_manifest_abi_symbols)
  if(NOT _pw_dense_manifest_abi_symbols STREQUAL _pw_dense_frozen_abi_symbols)
    message(FATAL_ERROR
      "pwofficial_dense_abi_symbols.txt differs from the frozen six-symbol ABI")
  endif()

  configure_file(
    cmake/FfiFailClosedTest.cc.in
    "${CMAKE_CURRENT_BINARY_DIR}/generated/tests/ffi_fail_closed_test.cc"
    COPYONLY)
  add_executable(
    pw_official_dense_ffi_fail_closed_test
    "${CMAKE_CURRENT_BINARY_DIR}/generated/tests/ffi_fail_closed_test.cc")
  if(PW_DENSE_ENABLE_OFFICIAL_FUSION)
    # Resolve every member of the merged archive so the in-tree StereoFusion
    # closure cannot hide an unresolved object behind normal archive selection.
    target_link_libraries(
      pw_official_dense_ffi_fail_closed_test
      PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,pw_official_dense_portable>")
  else()
    target_link_libraries(
      pw_official_dense_ffi_fail_closed_test PRIVATE PocketWorld::OfficialDense)
  endif()
  add_test(
    NAME pw_official_dense_ffi_fail_closed
    COMMAND pw_official_dense_ffi_fail_closed_test
            "${CMAKE_CURRENT_BINARY_DIR}/ffi-must-not-exist.ply")

  add_executable(pw_official_dense_abi_test
                 abi_tests/patch_match_abi_test.cc)
  target_link_libraries(
    pw_official_dense_abi_test PRIVATE PocketWorld::OfficialDense)
  add_test(NAME pw_official_dense_abi COMMAND pw_official_dense_abi_test)

  add_executable(pw_official_dense_dispatch_plan_test
                 vulkan_host/dispatch_plan_test.cc)
  target_link_libraries(
    pw_official_dense_dispatch_plan_test PRIVATE PocketWorld::OfficialDense)
  add_test(NAME pw_official_dense_dispatch_plan
           COMMAND pw_official_dense_dispatch_plan_test)

  add_executable(pw_official_dense_resource_arena_plan_test
                 vulkan_resource_arena/resource_arena_plan_test.cc)
  target_link_libraries(
    pw_official_dense_resource_arena_plan_test
    PRIVATE PocketWorld::OfficialDense)
  add_test(NAME pw_official_dense_resource_arena_plan
           COMMAND pw_official_dense_resource_arena_plan_test)

  if(PW_DENSE_ENABLE_VULKAN_RUNTIME)
    add_executable(
      pw_official_dense_vulkan_runtime_test
      vulkan_runtime/vulkan_runtime_test.cc
      vulkan_runtime/vulkan_runtime.cc
      vulkan_host/dispatch_plan.cc)
    target_compile_definitions(
      pw_official_dense_vulkan_runtime_test
      PRIVATE PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING=1)
    target_compile_features(
      pw_official_dense_vulkan_runtime_test PRIVATE cxx_std_17)
    target_include_directories(
      pw_official_dense_vulkan_runtime_test
      PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        "${PW_DENSE_VULKAN_INCLUDE_DIR}")
    add_test(NAME pw_official_dense_vulkan_runtime
             COMMAND pw_official_dense_vulkan_runtime_test)

    add_executable(pw_official_dense_resource_arena_test
                   vulkan_resource_arena/resource_arena_test.cc)
    target_link_libraries(
      pw_official_dense_resource_arena_test PRIVATE PocketWorld::OfficialDense)
    add_test(NAME pw_official_dense_resource_arena
             COMMAND pw_official_dense_resource_arena_test)

    add_executable(
      pw_official_dense_batch_executor_test
      vulkan_batch_executor/batch_executor_test.cc
      vulkan_batch_executor/batch_executor.cc
      vulkan_resource_arena/resource_arena.cc
      vulkan_resource_arena/resource_arena_plan.cc
      vulkan_runtime/vulkan_runtime.cc
      vulkan_host/dispatch_plan.cc
      vulkan_host/vulkan_host.cc)
    target_compile_definitions(
      pw_official_dense_batch_executor_test
      PRIVATE PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING=1)
    target_compile_features(
      pw_official_dense_batch_executor_test PRIVATE cxx_std_17)
    target_include_directories(
      pw_official_dense_batch_executor_test
      PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        "${PW_DENSE_VULKAN_INCLUDE_DIR}")
    add_test(NAME pw_official_dense_batch_executor
             COMMAND pw_official_dense_batch_executor_test)

    add_executable(
      pw_official_dense_vulkan_shader_bundle_test
      vulkan_shader_bundle/shader_bundle_test.cc)
    target_link_libraries(
      pw_official_dense_vulkan_shader_bundle_test
      PRIVATE PocketWorld::OfficialDense)
    add_test(NAME pw_official_dense_vulkan_shader_bundle
             COMMAND pw_official_dense_vulkan_shader_bundle_test)
  endif()

  add_executable(pw_official_dense_rng_contract_test
                 rng/rng_contract_test.cc)
  target_include_directories(
    pw_official_dense_rng_contract_test PRIVATE rng)
  target_compile_features(pw_official_dense_rng_contract_test PRIVATE cxx_std_17)
  add_test(NAME pw_official_dense_rng_contract
           COMMAND pw_official_dense_rng_contract_test)

  add_executable(pw_official_dense_colmap_xorwow_test
                 rng/colmap_xorwow_test.cc)
  target_include_directories(
    pw_official_dense_colmap_xorwow_test PRIVATE rng)
  target_compile_features(
    pw_official_dense_colmap_xorwow_test PRIVATE cxx_std_17)
  add_test(NAME pw_official_dense_colmap_xorwow
           COMMAND pw_official_dense_colmap_xorwow_test)

  add_executable(pw_official_dense_sweep_contract_test
                 sweep/sweep_contract_test.cc)
  target_include_directories(
    pw_official_dense_sweep_contract_test PRIVATE sweep)
  target_compile_features(
    pw_official_dense_sweep_contract_test PRIVATE cxx_std_17)
  add_test(NAME pw_official_dense_sweep_contract
           COMMAND pw_official_dense_sweep_contract_test)

  add_executable(pw_official_dense_anchored_transaction_test
                 file_transaction/anchored_transaction_test.cc)
  target_link_libraries(
    pw_official_dense_anchored_transaction_test
    PRIVATE PocketWorld::OfficialDense)
  add_test(NAME pw_official_dense_anchored_transaction
           COMMAND pw_official_dense_anchored_transaction_test)
endif()

install(
  TARGETS pw_official_dense_portable
  EXPORT PocketWorldOfficialDenseTargets
  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
install(
  DIRECTORY include/official_dense
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
  FILES_MATCHING PATTERN "*.h")
install(FILES
  workspace_io/workspace_io.h
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/workspace_io")
install(FILES
  patch_match_controller/patch_match_controller.h
  DESTINATION
    "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/patch_match_controller")
install(FILES
  file_transaction/anchored_transaction.h
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/file_transaction")
install(FILES
  vulkan_host/dispatch_plan.h
  vulkan_host/vulkan_host.h
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/vulkan_host")
install(FILES
  vulkan_runtime/vulkan_runtime.h
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/vulkan_runtime")
if(PW_DENSE_ENABLE_VULKAN_RUNTIME)
  install(FILES
    vulkan_shader_bundle/shader_bundle.h
    DESTINATION
      "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/vulkan_shader_bundle")
  install(FILES
    vulkan_shader_bundle/frozen_manifest.json
    DESTINATION
      "${CMAKE_INSTALL_DATADIR}/PocketWorldOfficialDense/vulkan_shader_bundle")
  install(
    DIRECTORY vulkan_shader_bundle/assets/
    DESTINATION
      "${CMAKE_INSTALL_DATADIR}/PocketWorldOfficialDense/vulkan_shader_bundle/assets"
    FILES_MATCHING PATTERN "*.spv")
endif()
if(PW_DENSE_ENABLE_APPLE_MOLTENVK)
  install(FILES
    vulkan_apple/moltenvk_loader.h
    DESTINATION
      "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/vulkan_apple")
endif()
install(FILES
  vulkan_resource_arena/resource_arena.h
  vulkan_resource_arena/resource_arena_plan.h
  DESTINATION
    "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/vulkan_resource_arena")
install(FILES
  vulkan_batch_executor/batch_executor.h
  DESTINATION
    "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/vulkan_batch_executor")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/fusion_bridge/stereo_fusion_bridge.h")
  install(FILES
    fusion_bridge/stereo_fusion_bridge.h
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/official_dense/fusion_bridge")
endif()
install(FILES
  ffi/include/pwofficial_dense_c.h
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(FILES
  ffi/pwofficial_dense_abi_symbols.txt
  DESTINATION "${CMAKE_INSTALL_DATADIR}/PocketWorldOfficialDense/abi")
install(FILES
  third_party/colmap-4.1.1/COPYING.txt
  DESTINATION "${CMAKE_INSTALL_DATADIR}/PocketWorldOfficialDense/licenses"
  RENAME COLMAP-4.1.1-COPYING.txt)
install(FILES
  third_party/colmap-4.1.1/src/thirdparty/VLFeat/LICENSE
  DESTINATION "${CMAKE_INSTALL_DATADIR}/PocketWorldOfficialDense/licenses"
  RENAME VLFeat-LICENSE.txt)
install(
  EXPORT PocketWorldOfficialDenseTargets
  NAMESPACE PocketWorld::
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/PocketWorldOfficialDense")
