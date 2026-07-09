# aether3d_ffi.podspec — pocketworld-local FORK of
# ~/Developer/aether_cpp/aether3d_ffi.podspec (v0.1.0-phase3).
#
# WHY THIS FORK EXISTS (2026-07-05, streaming-SfM capture integration):
# The shared dist/ ships the OLD sfm layout: a separate libaether_sfm.a
# (Jun 21) carrying the C ABI WITHOUT aether_sfm_finalize_async/_status —
# on-device dlsym failed with "symbol not found" at finalize. The Jun 29
# COLMAP-4.0.4 build folds the FULL ABI (13 aether_sfm_* symbols + dsp_sift
# + sift_match, superset of the old archive) INTO libglomap_core.a.
# Editing the shared podspec/dist would change the production
# pocketworld_flutter link too, so this repo vendors exactly ONE binary —
# vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a (Jun 29) — plus this
# podspec, and keeps referencing the shared dist for everything else
# (libaether3d_ffi.a, libceres.a, libglog.a, simulator stub).
#
# Device-link deltas vs the shared podspec:
#   • DROPPED  -force_load …/sfm/libaether_sfm.a   (ABI now inside
#     libglomap_core.a; force-loading both = duplicate symbols)
#   • CHANGED  -force_load libglomap_core.a → the LOCAL Jun-29 copy
#   • ADDED    -Wl,-u,_aether_sfm_finalize_async / _aether_sfm_finalize_status
#     (Release -dead_strip drops dlsym-only symbols without an explicit
#     "needed" marker — see the shared podspec's Phase 5.5 note)
# Simulator branch is UNCHANGED (shared stub archive; no finalize_async -u —
# the stub predates it and Dart gates on isSupported before any call).
Pod::Spec.new do |s|
  s.name             = 'aether3d_ffi'
  s.version          = '0.1.1'
  s.summary          = 'aether_cpp C ABI (pocketworld fork: streaming-SfM finalize_async).'
  s.description      = 'Pocketworld-local fork of the aether_cpp FFI pod; see header comment.'
  s.homepage         = 'https://github.com/Kyle-Wang0211/Aether3D'
  s.license          = { :type => 'Proprietary', :text => 'See aether_cpp/LICENSE' }
  s.author           = { 'Kyle Wang' => 'wkd20040211@gmail.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '14.0'

  # Public C headers (local copies, kept in lock-step with
  # aether_cpp/include — aether_sfm_c.h here is the finalize_async revision)
  # plus the pwsfm export shim: the Jun-29 archive is built with
  # -fvisibility=hidden, so its aether_sfm_* symbols get localized in the
  # final Runner link and dlsym can't see them. The shim re-exports pure
  # forwarders (pwsfm_*) with default visibility; the Dart FFI binding looks
  # those up instead. See src/pwsfm_export_shim.c.
  s.source_files        = [
    'include/aether/aether_version.h',
    'include/aether_glb_norm_c.h',
    'include/aether_depth_tile_c.h',
    'include/aether_sfm_c.h',
    'src/pwsfm_export_shim.c',
    # Tiled-GEMM Metal matcher (research tier): add_frame references
    # aether_gpu_match_gemm_pairs weakly; this TU provides it (kernel source
    # embedded, compiled at first use — no metallib packaging needed).
    'src/pwsfm_gpu_match.mm',
    # Capture telemetry (phys_footprint + thermalState), FFI-callable from the
    # SfM worker isolate. See src/pw_telemetry.mm.
    'src/pw_telemetry.mm',
  ]
  s.public_header_files = [
    'include/aether/aether_version.h',
    'include/aether_glb_norm_c.h',
    'include/aether_depth_tile_c.h',
    'include/aether_sfm_c.h',
  ]

  s.frameworks = 'Foundation', 'Metal', 'CoreVideo', 'IOSurface', 'QuartzCore', 'Accelerate'
  s.libraries  = 'c++', 'z'

  # Keep the local binary + headers around in the Pods checkout.
  s.preserve_paths = 'libs/**/*', 'include/**/*'

  # Search paths: shared dist (via the ~/Developer/dist symlink) for
  # libaether3d_ffi.a + ceres/glog + the simulator stub, exactly like the
  # shared podspec. PODS_TARGET_SRCROOT = <pocketworld>/vendor/aether_ffi,
  # so ../../.. = ~/Developer.
  s.pod_target_xcconfig = {
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]'        => '$(inherited) $(PODS_TARGET_SRCROOT)/../../../dist/libs/ios-arm64 $(PODS_TARGET_SRCROOT)/../../../dist/libs/ios-arm64/sfm',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => '$(inherited) $(PODS_TARGET_SRCROOT)/../../../dist/libs/ios-arm64-simulator $(PODS_TARGET_SRCROOT)/../../../dist/libs/ios-arm64-simulator/sfm',
    'OTHER_LDFLAGS'                              => '-laether3d_ffi',
    'VALID_ARCHS[sdk=iphoneos*]'                 => 'arm64',
    'VALID_ARCHS[sdk=iphonesimulator*]'          => 'arm64',
  }

  # Runner link line. PODS_ROOT = <pocketworld>/ios/Pods:
  #   $(PODS_ROOT)/../../../dist            → ~/Developer/dist   (shared)
  #   $(PODS_ROOT)/../../vendor/aether_ffi  → this pod's dir     (local)
  s.user_target_xcconfig = {
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]'        => '$(inherited) $(PODS_ROOT)/../../../dist/libs/ios-arm64 $(PODS_ROOT)/../../../dist/libs/ios-arm64/sfm',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => '$(inherited) $(PODS_ROOT)/../../../dist/libs/ios-arm64-simulator $(PODS_ROOT)/../../../dist/libs/ios-arm64-simulator/sfm',
    'VALID_ARCHS[sdk=iphonesimulator*]'          => 'arm64',
    'VALID_ARCHS[sdk=iphoneos*]'                 => 'arm64',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]'       => 'x86_64',
    # -Wl,-U,_aether_dsp_sift_extract_gpu: the archive's GPU-extract hook is
    # a WEAK reference by design ("targets that don't link the Dawn-backed
    # dsp_sift_gpu_c.cc still link; the use_gpu_extract path guards on
    # nullptr"). Mach-O needs the -U flag to honour that intent — the symbol
    # resolves to NULL at runtime and the in-ABI guard falls back to CPU.
    'OTHER_LDFLAGS[sdk=iphoneos*]'               => '$(inherited) -Wl,-U,_aether_dsp_sift_extract_gpu -force_load $(PODS_ROOT)/../../../dist/libs/ios-arm64/libaether3d_ffi.a -Wl,-u,_aether_version_string -Wl,-u,_aether_glb_norm_run -Wl,-u,_aether_glb_norm_options_default -Wl,-u,_aether_glb_norm_buffer_free -Wl,-u,_aether_glb_norm_result_str -force_load $(PODS_ROOT)/../../vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a -force_load $(PODS_ROOT)/../../vendor/aether_ffi/libs/ios-arm64/sfm/libpwsfm_gpu_extract.a $(PODS_ROOT)/../../../Aether3D-cross/aether_cpp/build-ios-device-dawn/third_party/dawn/src/dawn/native/Debug-iphoneos/libwebgpu_dawn.a -lceres -lglog -lsqlite3 -Wl,-u,_aether_sfm_run -Wl,-u,_aether_sfm_run_dir -Wl,-u,_aether_sfm_create -Wl,-u,_aether_sfm_add_frame -Wl,-u,_aether_sfm_finalize -Wl,-u,_aether_sfm_finalize_async -Wl,-u,_aether_sfm_finalize_status -Wl,-u,_aether_sfm_get_poses -Wl,-u,_aether_sfm_get_points -Wl,-u,_aether_sfm_points_free -Wl,-u,_aether_sfm_free -Wl,-u,_aether_sfm_options_default -Wl,-u,_aether_sfm_result_str -Wl,-u,_pwsfm_options_default -Wl,-u,_pwsfm_run -Wl,-u,_pwsfm_create -Wl,-u,_pwsfm_add_frame -Wl,-u,_pwsfm_finalize_async -Wl,-u,_pwsfm_finalize_status -Wl,-u,_pwsfm_get_poses -Wl,-u,_pwsfm_get_points -Wl,-u,_pwsfm_points_free -Wl,-u,_pwsfm_free -Wl,-u,_aether_sfm_get_points_tracked -Wl,-u,_aether_sfm_track_obs_free -Wl,-u,_pwsfm_get_points_tracked -Wl,-u,_pwsfm_track_obs_free -Wl,-u,_aether_sfm_debug_last -Wl,-u,_pwsfm_debug_last -Wl,-u,_aether_sfm_stream_stats -Wl,-u,_pwsfm_stream_stats -Wl,-u,_aether_sfm_get_preview_points -Wl,-u,_pwsfm_get_preview_points -Wl,-u,_aether_sfm_get_preview_tracked -Wl,-u,_pwsfm_get_preview_tracked -Wl,-u,_pw_telemetry -Wl,-u,_aether_gpu_match_gemm_pairs',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]'        => '$(inherited) -force_load $(PODS_ROOT)/../../../dist/libs/ios-arm64-simulator/libaether3d_ffi.a -Wl,-u,_aether_version_string -Wl,-u,_aether_glb_norm_run -Wl,-u,_aether_glb_norm_options_default -Wl,-u,_aether_glb_norm_buffer_free -Wl,-u,_aether_glb_norm_result_str -force_load $(PODS_ROOT)/../../../dist/libs/ios-arm64-simulator/sfm/libaether_sfm.a -Wl,-u,_aether_sfm_run -Wl,-u,_aether_sfm_run_dir -Wl,-u,_aether_sfm_create -Wl,-u,_aether_sfm_add_frame -Wl,-u,_aether_sfm_finalize -Wl,-u,_aether_sfm_get_poses -Wl,-u,_aether_sfm_get_points -Wl,-u,_aether_sfm_points_free -Wl,-u,_aether_sfm_free -Wl,-u,_aether_sfm_options_default -Wl,-u,_aether_sfm_result_str -Wl,-u,_pwsfm_options_default -Wl,-u,_pwsfm_run -Wl,-u,_pwsfm_create -Wl,-u,_pwsfm_add_frame -Wl,-u,_pwsfm_finalize_async -Wl,-u,_pwsfm_finalize_status -Wl,-u,_pwsfm_get_poses -Wl,-u,_pwsfm_get_points -Wl,-u,_pwsfm_points_free -Wl,-u,_pwsfm_free -Wl,-u,_pwsfm_get_points_tracked -Wl,-u,_pwsfm_track_obs_free -Wl,-u,_pwsfm_get_preview_tracked -Wl,-u,_pwsfm_debug_last -Wl,-u,_pwsfm_stream_stats -Wl,-u,_pw_telemetry -Wl,-u,_aether_gpu_match_gemm_pairs',
  }
end
