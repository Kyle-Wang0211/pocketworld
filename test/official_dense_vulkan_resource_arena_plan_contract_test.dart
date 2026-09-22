import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'vendor/official_dense/vulkan_resource_arena';

  test('resource arena plan is a pure checked CPU sizing contract', () {
    final header = File('$root/resource_arena_plan.h').readAsStringSync();
    final source = File('$root/resource_arena_plan.cc').readAsStringSync();

    expect(header, contains('struct ResourceArenaInput'));
    expect(header, contains('struct ResourceArenaPlan'));
    expect(header, contains('BuildResourceArenaPlan'));
    expect(header, contains('alias_groups_are_plan_local'));
    expect(header, contains('kUsageHostValues'));
    expect(source, contains('CheckedMultiply'));
    expect(source, contains('CheckedAdd'));
    expect(source, contains('graph_values >'));
    expect(source, contains('FitsSizeT'));
    expect(source, contains('ScalarType::kInt32'));
    expect(source, isNot(contains('vkCreate')));
    expect(source, isNot(contains('vkAllocate')));
    expect(source, isNot(contains('#include <vulkan/')));
    expect(source, isNot(contains('PW_DENSE_OVERALL_READY')));
  });

  test('strict C++17 exact-size and alias contract compiles and runs', () {
    final temp = Directory.systemTemp.createTempSync('pw-arena-plan-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = '${temp.path}/resource_arena_plan_test';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Wpedantic',
      '-Wconversion',
      '-Wsign-conversion',
      '-Werror',
      '-I$root',
      '-Ivendor/official_dense',
      '$root/resource_arena_plan_test.cc',
      '$root/resource_arena_plan.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('CMake builds and tests the plan without activating production', () {
    final cmake = File('vendor/official_dense/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('vulkan_resource_arena/resource_arena_plan.cc'));
    expect(cmake, contains('pw_official_dense_resource_arena_plan_test'));
    expect(cmake, contains('pw_official_dense_resource_arena_plan'));
    expect(cmake, contains('set(PW_DENSE_OVERALL_READY FALSE'));
  });

  test('memory report tool exposes K10 and K12 plans without Vulkan', () {
    final temp = Directory.systemTemp.createTempSync('pw-arena-memory-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = '${temp.path}/resource_memory_report';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Wpedantic',
      '-Wconversion',
      '-Wsign-conversion',
      '-Werror',
      '-I$root',
      '-Ivendor/official_dense',
      'vendor/official_dense/tools/resource_memory_report.cc',
      '$root/resource_arena_plan.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');

    Map<String, dynamic> report(String sources) {
      final run = Process.runSync(executable, <String>[
        '--width',
        '768',
        '--height',
        '576',
        '--sources',
        sources,
        '--phase',
        'full',
        '--streamed-source-depth',
      ]);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      return jsonDecode(run.stdout as String) as Map<String, dynamic>;
    }

    final k10 = report('10');
    final k12 = report('12');
    expect(k10['source_count'], 10);
    expect(k12['source_count'], 12);
    expect(k10['total_bytes'], greaterThan(0));
    expect(k12['total_bytes'], greaterThan(k10['total_bytes'] as num));
  });
}
