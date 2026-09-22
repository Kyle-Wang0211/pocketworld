import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'vendor/official_dense';
  const appleRoot = '$root/vulkan_apple';

  test('device probe is an isolated unsigned diagnostic app target', () {
    final cmake = File('$root/CMakeLists.txt').readAsStringSync();
    final infoPlist = File(
      '$appleRoot/device_probe_info.plist.in',
    ).readAsStringSync();

    expect(cmake, contains('pw_official_dense_moltenvk_device_probe'));
    expect(cmake, contains('MACOSX_BUNDLE'));
    expect(cmake, contains('com.kyle.PocketWorld.DenseProbe'));
    expect(cmake, contains('CODE_SIGNING_ALLOWED "NO"'));
    expect(cmake, contains('PW_DENSE_ENABLE_APPLE_DEVICE_PROBE'));
    expect(cmake, contains('PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC=1'));
    expect(cmake, isNot(contains('com.kyle.PocketWorld"')));
    expect(infoPlist, contains('com.kyle.PocketWorld.DenseProbe'));
    expect(infoPlist, contains('<key>LSRequiresIPhoneOS</key>'));
    expect(infoPlist, contains('<key>MinimumOSVersion</key>'));
    expect(infoPlist, contains('<string>15.0</string>'));
    expect(infoPlist, contains('<key>UIDeviceFamily</key>'));
  });

  test(
    'diagnostic target wires the real resource arena and canonical plan',
    () {
      final header = File(
        '$appleRoot/patch_match_sequence_probe.h',
      ).readAsStringSync();
      final source = File(
        '$appleRoot/patch_match_sequence_probe.cc',
      ).readAsStringSync();
      final runtimeHeader = File(
        '$root/vulkan_runtime/vulkan_runtime.h',
      ).readAsStringSync();
      final runtimeSource = File(
        '$root/vulkan_runtime/vulkan_runtime.cc',
      ).readAsStringSync();
      final executorHeader = File(
        '$root/vulkan_batch_executor/batch_executor.h',
      ).readAsStringSync();
      final executorSource = File(
        '$root/vulkan_batch_executor/batch_executor.cc',
      ).readAsStringSync();

      expect(header, contains('RunMoltenVkPatchMatchSequenceProbe() noexcept'));
      expect(source, contains('BuildResourceArenaBatch'));
      expect(source, contains('VulkanHostResourceAllocationProvider'));
      expect(source, contains('CanonicalShaderBundle()'));
      expect(source, contains('ExecuteResourceArenaBatchForDiagnostic'));
      expect(source, contains('diagnostic_certification_override'));
      expect(runtimeHeader, contains('RecordNativeForDiagnostic'));
      expect(runtimeSource, contains('RecordNativeForDiagnostic'));
      expect(
        executorHeader,
        contains('ExecuteResourceArenaBatchForDiagnostic'),
      );
      expect(
        executorSource,
        contains('ExecuteResourceArenaBatchForDiagnostic'),
      );
      expect(runtimeHeader, contains('PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC'));
      expect(executorHeader, contains('PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC'));
    },
  );

  test('host diagnostic can stop after the bounded synthetic probe', () {
    final source = File(
      '$appleRoot/device_probe_main.cc',
    ).readAsStringSync();

    expect(source, contains('PW_DENSE_PROBE_SYNTHETIC_ONLY'));
  });

  test('diagnostic build alone can expose completed per-image readbacks', () {
    final arenaHeader = File(
      '$root/vulkan_resource_arena/resource_arena.h',
    ).readAsStringSync();
    final arenaSource = File(
      '$root/vulkan_resource_arena/resource_arena.cc',
    ).readAsStringSync();

    expect(arenaHeader, contains('DiagnosticImageReadback'));
    expect(arenaHeader, contains('DiagnosticReadbackForImage'));
    expect(arenaHeader, contains('PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC'));
    expect(arenaSource, contains('DiagnosticReadbackForImage'));
    expect(arenaSource, contains('photometric_depth'));
    expect(arenaSource, contains('geometric_depth'));
    expect(arenaSource, contains('photometric_normal'));
    expect(arenaSource, contains('geometric_normal'));
    expect(arenaSource, contains('geometric_mask'));
  });

  test(
    'frozen scene source selection is delegated to the official COLMAP API',
    () {
      final exporter = File(
        '$root/tools/colmap_selection_export.cc',
      ).readAsStringSync();

      expect(exporter, contains('#include <colmap/mvs/model.h>'));
      expect(exporter, contains('model.ReadFromCOLMAP'));
      expect(exporter, contains('model.GetMaxOverlappingImages'));
      expect(exporter, contains('--max-source-images'));
      expect(exporter, contains('--min-triangulation-angle'));
      expect(exporter, contains('--binary-packet-output'));
      expect(exporter, contains('model.ComputeDepthRanges'));
      expect(exporter, contains('GetImageName'));
      final cmake = File('$root/CMakeLists.txt').readAsStringSync();
      expect(cmake, contains('pw_official_dense_selection_export'));
      expect(exporter, isNot(contains('ComputeSharedPoints')));
      expect(exporter, isNot(contains('partial_sort')));
    },
  );

  test('frozen real-scene fixture has a strict portable reader', () {
    final header = File(
      '$root/vulkan_apple/frozen_scene_loader.h',
    ).readAsStringSync();
    final source = File(
      '$root/vulkan_apple/frozen_scene_loader.cc',
    ).readAsStringSync();

    expect(header, contains('LoadFrozenScene'));
    expect(header, contains('LoadFrozenGrayPgm'));
    expect(source, contains("'P', 'W', 'S', 'C', 'E', 'N', 'E', '1'"));
    expect(source, contains('tokens[0] != "P5"'));
    expect(source, contains('expected_width'));
    expect(source, contains('expected_height'));
    expect(source, isNot(contains('ImageIO')));
    expect(source, isNot(contains('UIImage')));
  });

  test(
    'real-scene probe preserves COLMAP source ordering for its reference',
    () {
      final header = File('$appleRoot/frozen_scene_probe.h').readAsStringSync();
      final source = File(
        '$appleRoot/frozen_scene_probe.cc',
      ).readAsStringSync();

      expect(header, contains('RunFrozenSceneInputProbe'));
      expect(source, contains('LoadFrozenScene'));
      expect(source, contains('LoadFrozenGrayPgm'));
      expect(source, contains('source_indices'));
      expect(source, contains('BuildResourceArenaBatch'));
      expect(source, contains('ExecuteResourceArenaBatchForDiagnostic'));
      expect(source, contains('not_cuda_parity'));
      expect(source, isNot(contains('partial_sort')));
    },
  );

  test(
    'real-scene probe follows COLMAP per-reference photometric scheduling',
    () {
      final source = File(
        '$appleRoot/frozen_scene_probe.cc',
      ).readAsStringSync();
      final plan = File(
        '$root/vulkan_host/dispatch_plan.cc',
      ).readAsStringSync();
      final executor = File(
        '$root/vulkan_batch_executor/batch_executor.cc',
      ).readAsStringSync();

      expect(source, contains('PlanPhase::kPhotometricOnly'));
      expect(source, contains('PlanPhase::kGeometricOnly'));
      expect(source, contains('WriteDiagnosticPhotometricMaps'));
      expect(source, contains('PW_DENSE_PROBE_REAL_MODE'));
      expect(source, contains('photo_ref0'));
      expect(source, contains('WriteDiagnosticColmapMaps'));
      expect(source, contains('layered_source_depth'));
      expect(source, contains('reference_photometric_depth'));
      expect(source, contains('reference_photometric_normal'));
      expect(source, contains('reference_depth_f32'));
      expect(source, contains('reference_normal_f32'));
      expect(source, contains('ReadFloatMatrix'));
      expect(source, contains('LoadPersistedPhotometricState'));
      expect(source, contains('.photometric.bin'));
      expect(source, isNot(contains('kReferenceSlot, PlanPhase::kFull')));
      expect(source, contains('SummarizeResourceArenaMemory'));
      expect(source, contains('device_local_bytes'));
      expect(source, contains('host_upload_bytes'));
      expect(source, contains('host_readback_bytes'));
      expect(source, contains('peak_planned_bytes'));
      expect(source, contains('FrozenReferenceQueueSubmitCount'));
      expect(source, contains('expected_queue_submits'));
      expect(source, contains('queue_submit_count'));
      expect(source, isNot(contains('member_indices.push_back(static_cast')));
      expect(plan, contains('PlanPhase::kPhotometricOnly'));
      expect(executor, contains('input.plan_options'));
    },
  );

  test(
    'optional full-scene mode preserves the official global phase barrier',
    () {
      final source = File(
        '$appleRoot/frozen_scene_probe.cc',
      ).readAsStringSync();

      expect(source, contains('full_scene'));
      expect(source, contains('RunAllPhotometricReferences'));
      expect(source, contains('RunAllGeometricReferences'));
      expect(source, contains('LoadLayeredSourceDepths'));
      expect(source, contains('full_scene_photometric_complete'));
      expect(source, contains('full_scene_geometric_complete'));
      expect(source, contains('HasPersistedPhotometricMaps'));
      expect(source, contains('HasPersistedGeometricMaps'));
      expect(source, contains('photometric_resume_skip'));
      expect(source, contains('geometric_resume_skip'));
      final photoResume = source.substring(
        source.indexOf('bool HasPersistedPhotometricMaps'),
        source.indexOf('bool HasPersistedGeometricMaps'),
      );
      final geometricResume = source.substring(
        source.indexOf('bool HasPersistedGeometricMaps'),
        source.indexOf('bool RunAllPhotometricReferences'),
      );
      expect(photoResume, contains('LoadPersistedPhotometricState'));
      expect(geometricResume, contains('ReadFloatMatrix'));
      expect(geometricResume, contains('ReadConsistencyGraph'));
      expect(
        source.indexOf('RunAllPhotometricReferences'),
        lessThan(source.indexOf('RunAllGeometricReferences')),
      );
      expect(source, isNot(contains('window_size')));
      expect(source, isNot(contains('overlap_frames')));
    },
  );

  test(
    'diagnostic export writes COLMAP-compatible map paths without fusion',
    () {
      final header = File(
        '$appleRoot/diagnostic_map_export.h',
      ).readAsStringSync();
      final source = File(
        '$appleRoot/diagnostic_map_export.cc',
      ).readAsStringSync();

      expect(header, contains('WriteDiagnosticColmapMaps'));
      expect(header, contains('WriteDiagnosticPhotometricMaps'));
      expect(source, contains('CreateStandardWorkspace'));
      expect(source, contains('WriteFloatMatrix'));
      expect(source, contains('WriteConsistencyGraph'));
      expect(source, contains('.photometric.bin'));
      expect(source, contains('.geometric.bin'));
      expect(source, isNot(contains('StereoFusion')));
    },
  );

  test('probe uses the frozen reference shader without relaxing gates', () {
    final header = File('$appleRoot/device_probe.h').readAsStringSync();
    final source = File('$appleRoot/device_probe.cc').readAsStringSync();
    final mainSource = File(
      '$appleRoot/device_probe_main.cc',
    ).readAsStringSync();
    final hostSource = File(
      '$appleRoot/device_probe_uikit_host.mm',
    ).readAsStringSync();

    expect(header, contains('RunMoltenVkDeviceProbe() noexcept'));
    expect(source, contains('MoltenVkExternalLoader()'));
    expect(source, contains('VulkanHost::Probe'));
    expect(source, contains('VulkanHost::Create'));
    expect(source, contains('CanonicalShaderBundle()'));
    expect(source, contains('PipelineKind::kReferenceFilter'));
    expect(source, contains('kWidth = 4'));
    expect(source, contains('kHeight = 4'));
    expect(source, contains('vkCmdDispatch'));
    expect(source, contains('CpuReferenceFilter'));
    expect(source, contains('std::memcpy'));
    expect(source, isNot(contains('std::bit_cast')));
    expect(mainSource, contains('std::printf("%s\\n"'));
    expect(mainSource, contains('RunDeviceProbeSequence'));
    expect(mainSource, contains('PW_DENSE_PROBE_REAL_MODE'));
    expect(mainSource, contains('RunFrozenSceneInputProbe(executable_path)'));
    expect(
      mainSource.indexOf('PW_DENSE_PROBE_REAL_MODE'),
      lessThan(mainSource.indexOf('RunMoltenVkDeviceProbe()')),
    );
    expect(hostSource, contains('UIApplicationMain'));
    expect(hostSource, contains('std::thread'));
    expect(hostSource, contains('std::_Exit(success ? 0 : 1)'));

    final runtime = File(
      '$root/vulkan_runtime/vulkan_runtime.cc',
    ).readAsStringSync();
    expect(runtime, contains('kPcgAdaptationNotCertified'));
    expect(runtime, contains('kTextureParityNotCertified'));
    expect(runtime, contains('kFullSweepNotCertified'));
    expect(source, isNot(contains('PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING')));
  });

  test('probe core remains C++ with one no-Swift UIKit lifecycle host', () {
    final platformSources = Directory(appleRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              file.path.toLowerCase().endsWith('.swift') ||
              file.path.toLowerCase().endsWith('.m') ||
              file.path.toLowerCase().endsWith('.mm'),
        )
        .map((file) => file.path)
        .toList();
    expect(
      platformSources,
      equals(<String>['$appleRoot/device_probe_uikit_host.mm']),
    );
  });

  test(
    'iOS 26 probe requests official continued background GPU execution',
    () {
      final cmake = File('$root/CMakeLists.txt').readAsStringSync();
      final infoPlist = File(
        '$appleRoot/device_probe_info.plist.in',
      ).readAsStringSync();
      final entitlements = File(
        '$appleRoot/device_probe_entitlements.plist',
      ).readAsStringSync();
      final hostSource = File(
        '$appleRoot/device_probe_uikit_host.mm',
      ).readAsStringSync();

      expect(cmake, contains('BackgroundTasks'));
      expect(
        infoPlist,
        contains('BGTaskSchedulerPermittedIdentifiers'),
      );
      expect(
        infoPlist,
        contains('com.kyle.PocketWorld.DenseProbe.dense'),
      );
      expect(infoPlist, contains('<string>processing</string>'));
      expect(
        entitlements,
        contains(
          'com.apple.developer.background-tasks.continued-processing.gpu',
        ),
      );
      expect(hostSource, contains('BGContinuedProcessingTask'));
      expect(hostSource, contains('BGContinuedProcessingTaskRequest'));
      expect(hostSource, contains('supportedResources'));
      expect(
        hostSource,
        contains('BGContinuedProcessingTaskRequestResourcesGPU'),
      );
      expect(hostSource, contains('requiredResources'));
      expect(hostSource, contains('expirationHandler'));
      expect(hostSource, contains('task.progress'));
      expect(hostSource, contains('completedUnitCount'));
      expect(hostSource, contains('setTaskCompletedWithSuccess'));
      expect(
        hostSource,
        isNot(contains('beginBackgroundTaskWithExpirationHandler')),
      );
    },
  );

  test('macOS host probe runs the identical frozen-scene C++ entrypoint', () {
    final cmake = File('$root/CMakeLists.txt').readAsStringSync();
    final cli = File(
      '$appleRoot/device_probe_cli_host.cc',
    ).readAsStringSync();
    final frozenSource = File(
      '$appleRoot/frozen_scene_probe.cc',
    ).readAsStringSync();

    expect(cmake, contains('PW_DENSE_ENABLE_APPLE_HOST_PROBE'));
    expect(
      cmake,
      contains(
        'PW_DENSE_ENABLE_APPLE_DEVICE_PROBE OR\n   PW_DENSE_ENABLE_APPLE_HOST_PROBE',
      ),
    );
    expect(cmake, contains('pw_official_dense_moltenvk_host_probe'));
    expect(cmake, contains('device_probe_cli_host.cc'));
    expect(cmake, contains('macos-arm64_x86_64'));
    expect(cmake, contains('MoltenVK/MoltenVK/static/MoltenVK.xcframework'));
    expect(cmake, contains('AppKit'));
    expect(cmake, contains('NAMES IOKit'));
    expect(cli, contains('RunDeviceProbeSequence(argv[0])'));
    expect(cli, isNot(contains('RunStereoFusion')));
    expect(frozenSource, contains('PW_DENSE_PROBE_OUTPUT_ROOT'));
    expect(frozenSource, contains('PW_DENSE_PROBE_REFERENCE_SLOT'));
    expect(frozenSource, contains('photo_ref'));
    expect(frozenSource, contains('geo_ref'));
  });
}
