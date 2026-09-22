import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'vendor/official_dense/vulkan_runtime';

  test('runtime consumes the frozen ten-shader PCG manifest', () {
    final header = File('$root/vulkan_runtime.h').readAsStringSync();
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();

    expect(header, contains('kShaderCount = 10'));
    for (final shader in const <String>[
      'ref_filter/filter_u8.comp',
      'rng/init_openmvs_pcg.comp',
      'normal_ops/init_normal_openmvs_pcg.comp',
      'initial_cost/compute_initial_cost.comp',
      'sweep/sweep_full_openmvs_pcg.comp',
      'mat_ops/rotate_f32.comp',
      'mat_ops/transpose_f32.comp',
      'mat_ops/flip_horizontal_f32.comp',
      'normal_ops/rotate_normal_f32.comp',
      'depth_ops/init_depth_openmvs_pcg.comp',
    ]) {
      expect(source, contains('"$shader"'));
    }
    expect(header, contains('a0d785fba74b2664f31edc4a29026a8b27c00f67'));
    expect(header, contains('../vulkan_host/dispatch_plan.h'));
    expect(source, contains('request.plan->steps'));
  });

  test('runtime shader whitelist matches every frozen bundle identity', () {
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();
    final manifest = jsonDecode(
      File(
        'vendor/official_dense/vulkan_shader_bundle/frozen_manifest.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    final shaders = (manifest['shaders'] as List).cast<Map<String, dynamic>>();
    for (final shader in shaders) {
      expect(source, contains(shader['source_sha256'] as String));
      expect(source, contains(shader['spirv_sha256'] as String));
    }
  });

  test('production runtime is tied to all three fail-closed contracts', () {
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();

    expect(source, contains('rng::CanDispatchRngBackend()'));
    expect(source, contains('cost_ops::TextureFixtureAllowsParity()'));
    expect(source, contains('sweep::CanDispatchSweepBackend()'));
    expect(source, contains('kPcgAdaptationNotCertified'));
    expect(source, contains('kTextureParityNotCertified'));
    expect(source, contains('kFullSweepNotCertified'));
    expect(source, contains('PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING'));
    expect(source, isNot(contains('ply')));
    expect(source, isNot(contains('fallback')));
  });

  test('recorder follows frozen PatchMatch state transitions', () {
    final header = File('$root/vulkan_runtime.h').readAsStringSync();
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();

    for (final contract in const <String>[
      'ModeResources',
      'RotationCalibration',
      'ConsistencyGraphInput',
      'SerializeConsistencyGraph',
      'SamplerMetadata',
      'CopyBufferRotatedU32',
      'kOpenMvsPcgDepthInitialize',
    ]) {
      expect(header, contains(contract));
    }
    expect(header, isNot(contains('InitializePhotometricDepth')));
    expect(source, contains('patch.prev_sel_prob_weight'));
    expect(source, contains('patch.perturbation'));
    expect(source, contains('specialization = step.sweep_flags'));
    expect(source, contains('OfficialNccNormalizationBits'));
    expect(source, contains('resources.depth_readback'));
    expect(source, contains('resources.normal_readback'));
    expect(source, contains('resources.mask_readback'));
    expect(source, contains('ResourceScalarType::kUint32'));
    expect(source, isNot(contains('specialization = 5U')));
  });

  test(
    'native path owns Vulkan pipelines descriptors commands and barriers',
    () {
      final source = File('$root/vulkan_runtime.cc').readAsStringSync();

      for (final symbol in const <String>[
        'vkCreateDescriptorSetLayout',
        'vkCreatePipelineLayout',
        'vkCreateShaderModule',
        'vkCreateComputePipelines',
        'vkCreateDescriptorPool',
        'vkAllocateDescriptorSets',
        'vkUpdateDescriptorSets',
        'vkResetCommandBuffer',
        'vkBeginCommandBuffer',
        'vkCmdBindPipeline',
        'vkCmdBindDescriptorSets',
        'vkCmdPushConstants',
        'vkCmdDispatch',
        'vkCmdPipelineBarrier',
        'vkCmdCopyBuffer',
        'vkCmdClearColorImage',
        'vkCmdFillBuffer',
        'vkEndCommandBuffer',
        'vkQueueSubmit',
        'vkQueueWaitIdle',
      ]) {
        expect(source, contains(symbol));
      }
      expect(source, contains('VK_ACCESS_SHADER_WRITE_BIT'));
      expect(source, contains('VK_ACCESS_TRANSFER_WRITE_BIT'));
      expect(source, contains('VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER'));
      expect(source, contains('VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL'));
      expect(source, contains('VK_IMAGE_LAYOUT_UNDEFINED'));
      expect(source, contains('vkResetCommandBuffer_(command_buffer_, 0)'));
      expect(source, contains('ResetThenBeginCommandBuffer'));
      expect(
        source,
        contains('VK_PIPELINE_CREATE_DISPATCH_BASE_BIT'),
        reason:
            'vkCmdDispatchBase with a non-zero base group requires the '
            'compute pipeline dispatch-base creation flag',
      );
    },
  );

  test('PatchMatch uses the official one-grid kernel launch granularity', () {
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();
    final dispatchStart = source.indexOf('bool Dispatch(');
    final dispatchEnd = source.indexOf('bool RotateFloat(', dispatchStart);
    expect(dispatchStart, greaterThanOrEqualTo(0));
    expect(dispatchEnd, greaterThan(dispatchStart));
    final dispatch = source.substring(dispatchStart, dispatchEnd);

    expect(dispatch, contains('backend_->BindAndDispatch('));
    expect(dispatch, isNot(contains('BindAndDispatchPartitioned')));
  });

  test('initial cost and sweep bind the same official source image sampler', () {
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();

    final writesStart = source.indexOf('std::vector<Write> WritesFor(');
    final writesEnd = source.indexOf('struct FilterPC', writesStart);
    expect(writesStart, greaterThanOrEqualTo(0));
    expect(writesEnd, greaterThan(writesStart));
    final writes = source.substring(writesStart, writesEnd);
    final initialWritesStart = writes.indexOf('case PipelineKind::kInitialCost:');
    final initialWritesEnd = writes.indexOf(
      'case PipelineKind::kFullSweep:',
      initialWritesStart,
    );
    final initialWrites = writes.substring(initialWritesStart, initialWritesEnd);
    expect(initialWrites, contains('{14, true, resources.bindings[14][rotation]}'));
    expect(initialWrites, isNot(contains('buffer(14, 14)')));

    final specsStart = source.indexOf('std::vector<DescriptorSpec> DescriptorSpecs(');
    final specsEnd = source.indexOf('class NativeBackend', specsStart);
    expect(specsStart, greaterThanOrEqualTo(0));
    expect(specsEnd, greaterThan(specsStart));
    final specs = source.substring(specsStart, specsEnd);
    final initialSpecsStart = specs.indexOf('case PipelineKind::kInitialCost:');
    final initialSpecsEnd = specs.indexOf(
      'case PipelineKind::kFullSweep:',
      initialSpecsStart,
    );
    final initialSpecs = specs.substring(initialSpecsStart, initialSpecsEnd);
    expect(
      initialSpecs,
      contains('{14, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER}'),
    );
  });

  test('PatchMatch retains the official host synchronization boundaries', () {
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();
    final synchronizeStart = source.indexOf('bool HostSynchronize(');
    final synchronizeEnd = source.indexOf(
      'bool Dispatch(',
      synchronizeStart,
    );
    expect(synchronizeStart, greaterThanOrEqualTo(0));
    expect(synchronizeEnd, greaterThan(synchronizeStart));
    final synchronize = source.substring(
      synchronizeStart,
      synchronizeEnd,
    );

    expect(synchronize, contains('Barrier(result)'));
    expect(synchronize, contains('SubmitWaitAndContinue'));
  });

  test('Android uses system Vulkan; Apple and Harmony require injection', () {
    final header = File('$root/vulkan_runtime.h').readAsStringSync();
    final source = File('$root/vulkan_runtime.cc').readAsStringSync();

    expect(header, contains('get_instance_proc_addr'));
    expect(source, contains('__ANDROID__'));
    expect(source, contains('&vkGetInstanceProcAddr'));
    expect(source, contains('__APPLE__'));
    expect(source, contains('PW_OFFICIAL_DENSE_HARMONY'));
    expect(source, contains('kExternalLoaderRequired'));
    expect(
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.swift')),
      isEmpty,
    );
    expect(File('$root/CMakeLists.txt').existsSync(), isFalse);
  });

  test('strict C++17 fake-dispatch state machine compiles and runs', () {
    final temp = Directory.systemTemp.createTempSync('pw-vulkan-runtime-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = '${temp.path}/vulkan_runtime_test';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Wpedantic',
      '-Wconversion',
      '-Wsign-conversion',
      '-Werror',
      '-DPW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING=1',
      '-I$root',
      '-Ivendor/official_dense',
      '$root/vulkan_runtime_test.cc',
      '$root/vulkan_runtime.cc',
      'vendor/official_dense/vulkan_host/dispatch_plan.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('Android NDK r29 accepts the native Vulkan path', () {
    final candidates = <String>{
      if (Platform.environment['ANDROID_NDK_HOME'] case final String value)
        value,
      if (Platform.environment['ANDROID_NDK_ROOT'] case final String value)
        value,
      '/opt/homebrew/share/android-ndk',
    };
    final ndk = candidates
        .map(Directory.new)
        .where((directory) => directory.existsSync())
        .firstOrNull;
    expect(ndk, isNotNull, reason: 'Android NDK r29 is required');
    final properties = File(
      '${ndk!.path}/source.properties',
    ).readAsStringSync();
    expect(properties, contains('Pkg.Revision = 29.'));

    final compiler =
        '${ndk.path}/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang++';
    final sysroot =
        '${ndk.path}/toolchains/llvm/prebuilt/darwin-x86_64/sysroot';
    final syntax = Process.runSync(compiler, <String>[
      '--target=aarch64-none-linux-android24',
      '--sysroot=$sysroot',
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Wpedantic',
      '-Wconversion',
      '-Wsign-conversion',
      '-Werror',
      '-I$root',
      '-Ivendor/official_dense',
      '-fsyntax-only',
      '$root/vulkan_runtime.cc',
    ]);
    expect(syntax.exitCode, 0, reason: '${syntax.stdout}\n${syntax.stderr}');
  });
}
