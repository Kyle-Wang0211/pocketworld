import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const sourceRoot = 'vendor/official_dense/patch_match_controller';
  const implementation = '$sourceRoot/patch_match_controller.cc';

  test('PatchMatchOptions preserves official COLMAP 4.1.1 validation range',
      () async {
    final temporary = await Directory.systemTemp.createTemp(
      'official_dense_patch_match_options_',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final executable = '${temporary.path}/options_test';
    final compile = await Process.run('xcrun', <String>[
      'clang++',
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$sourceRoot',
      implementation,
      '$sourceRoot/patch_match_controller_test.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('controller preserves COLMAP 4.1.1 problem selection and two-stage run',
      () async {
    final temporary = await Directory.systemTemp.createTemp(
      'official_dense_patch_match_controller_',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final fixture = File('${temporary.path}/fixture.cc');
    await fixture.writeAsString(r'''
#include "patch_match_controller.h"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace od = pocketworld::official_dense::patch_match;
namespace fs = std::filesystem;

int Fail(int code) { return code; }

class Reader final : public od::WorkspaceReader {
 public:
  od::Status Read(const od::WorkspaceReadRequest& request,
                  od::WorkspaceSnapshot* snapshot) override {
    if (request.workspace_format != "COLMAP") {
      return od::Status::Invalid("format changed");
    }
    if (request.input_type != "photometric" || request.image_as_rgb ||
        request.max_image_size != -1 || request.cache_size != 32.0) {
      return od::Status::Invalid("workspace options changed");
    }
    snapshot->stereo_folder = "stereo";
    snapshot->images = {
        {0, "a.jpg", 1.0, 10.0, {{1, 10}, {2, 20}},
         {{1, 2.0 * 3.14159265358979323846 / 180.0},
          {2, 0.5 * 3.14159265358979323846 / 180.0}}},
        {1, "b.jpg", 2.0, 20.0, {}, {}},
        {2, "c.jpg", 3.0, 30.0, {}, {}},
    };
    return od::Status::Ok();
  }
};

struct Event {
  bool wait = false;
  od::PatchMatchRequest request;
};

class Backend final : public od::VulkanPatchMatchBackend {
 public:
  explicit Backend(std::vector<Event>* events) : events_(events) {}
  od::Status Submit(const od::PatchMatchRequest& request) override {
    events_->push_back({false, request});
    return od::Status::Ok();
  }
  od::Status WaitAll() override {
    events_->push_back({true, {}});
    return od::Status::Ok();
  }

 private:
  std::vector<Event>* events_;
};

class Factory final : public od::VulkanBackendFactory {
 public:
  explicit Factory(std::vector<Event>* events) : events_(events) {}
  std::vector<int> EnumerateDevices() const override { return {7}; }
  std::unique_ptr<od::VulkanPatchMatchBackend> Create(
      int device_index) const override {
    if (device_index != 7) return nullptr;
    return std::make_unique<Backend>(events_);
  }

 private:
  std::vector<Event>* events_;
};

int main(int argc, char** argv) {
  if (argc != 2) return Fail(1);
  const fs::path root = argv[1];
  fs::create_directories(root / "stereo");
  {
    std::ofstream config(root / "stereo" / "patch-match.cfg");
    config << "# exact COLMAP pair format\n"
           << "a.jpg\n"
           << "__auto__, 1\n"
           << "\n"
           << "b.jpg\n"
           << "a.jpg, c.jpg\n"
           << "c.jpg\n"
           << "__all__\n";
  }

  const od::PatchMatchOptions defaults;
  if (defaults.depth_min != -1.0 || defaults.depth_max != -1.0 ||
      defaults.sigma_spatial != -1.0 || defaults.sigma_color != 0.2 ||
      defaults.ncc_sigma != 0.6 || defaults.min_triangulation_angle != 1.0 ||
      defaults.incident_angle_sigma != 0.9 ||
      defaults.geom_consistency_regularizer != 0.3 ||
      defaults.geom_consistency_max_cost != 3.0 ||
      defaults.filter_min_ncc != 0.1 ||
      defaults.filter_min_triangulation_angle != 3.0 ||
      defaults.filter_geom_consistency_max_cost != 1.0 ||
      defaults.cache_size != 32.0 || defaults.gpu_index != "-1" ||
      defaults.max_image_size != -1 || defaults.window_radius != 5 ||
      defaults.window_step != 1 || defaults.num_samples != 15 ||
      defaults.num_iterations != 5 ||
      defaults.filter_min_num_consistent != 2 ||
      defaults.num_threads != -1 || !defaults.geom_consistency ||
      !defaults.filter || defaults.allow_missing_files ||
      defaults.write_consistency_graph) {
    return Fail(2);
  }

  auto reader = std::make_shared<Reader>();
  std::vector<Event> events;
  auto factory = std::make_shared<Factory>(&events);
  od::PatchMatchOptions run_options = defaults;
  run_options.window_radius = 20;
  run_options.window_step = 2;
  od::PatchMatchController controller(
      run_options, root, "COLMAP", "", {}, reader, factory);
  const od::Status status = controller.Run();
  if (!status.ok()) return Fail(3);
  if (events.size() != 8 || events[0].wait || events[1].wait ||
      events[2].wait || !events[3].wait || events[4].wait ||
      events[5].wait || events[6].wait || !events[7].wait) {
    return Fail(4);
  }
  const auto& photo_a = events[0].request;
  const auto& photo_b = events[1].request;
  const auto& photo_c = events[2].request;
  const auto& geometric_a = events[4].request;
  const auto& geometric_b = events[5].request;
  if (photo_a.problem.ref_image_idx != 0 ||
      photo_a.problem.src_image_idxs != std::vector<int>{1} ||
      photo_b.problem.ref_image_idx != 1 ||
      photo_b.problem.src_image_idxs != (std::vector<int>{0, 2}) ||
      photo_c.problem.ref_image_idx != 2 ||
      photo_c.problem.src_image_idxs != (std::vector<int>{0, 1})) {
    return Fail(5);
  }
  if (photo_a.options.geom_consistency || photo_a.options.filter ||
      photo_b.options.geom_consistency || photo_b.options.filter ||
      !geometric_a.options.geom_consistency ||
      !geometric_a.options.filter ||
      !geometric_b.options.geom_consistency ||
      !geometric_b.options.filter) {
    return Fail(6);
  }
  if (photo_a.options.depth_min != 1.0 ||
      photo_a.options.depth_max != 10.0 ||
      photo_a.options.sigma_spatial != 20.0 ||
      photo_a.options.window_radius != 20 ||
      photo_a.options.window_step != 2 ||
      photo_a.options.gpu_index != "7" ||
      photo_a.options.filter_min_num_consistent != 1) {
    return Fail(7);
  }
  if (photo_a.output.depth_map.filename() != "a.jpg.photometric.bin" ||
      geometric_a.output.depth_map.filename() != "a.jpg.geometric.bin" ||
      geometric_a.output.normal_map.filename() != "a.jpg.geometric.bin" ||
      geometric_a.output.consistency_graph.filename() !=
          "a.jpg.geometric.bin") {
    return Fail(8);
  }

  // The production default is deliberately unavailable until the Vulkan
  // execution backend passes the frozen CUDA parity gate.
  auto unavailable = std::make_shared<od::UnavailableVulkanBackendFactory>();
  od::PatchMatchController unavailable_controller(
      defaults, root, "COLMAP", "", {}, reader, unavailable);
  const od::Status unavailable_status = unavailable_controller.Run();
  if (unavailable_status.code != od::StatusCode::kUnavailable) return Fail(9);
  if (fs::exists(root / "stereo" / "depth_maps")) return Fail(10);

  od::PatchMatchOptions invalid_options = defaults;
  invalid_options.window_radius = 33;
  std::vector<Event> invalid_events;
  auto invalid_factory = std::make_shared<Factory>(&invalid_events);
  od::PatchMatchController invalid_controller(
      invalid_options, root, "COLMAP", "", {}, reader, invalid_factory);
  const od::Status invalid_status = invalid_controller.Run();
  if (invalid_status.code != od::StatusCode::kInvalidArgument) return Fail(11);
  if (!invalid_events.empty()) return Fail(12);
  return 0;
}
''');

    final executable = '${temporary.path}/fixture';
    final compile = await Process.run('xcrun', <String>[
      'clang++',
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$sourceRoot',
      implementation,
      fixture.path,
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');

    final run = await Process.run(executable, <String>[
      '${temporary.path}/workspace',
    ]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('controller is portable C++17 and contains no Swift or CUDA fallback',
      () async {
    final files = Directory(sourceRoot).listSync(recursive: true);
    expect(
      files.whereType<File>().where(
            (file) => file.path.toLowerCase().endsWith('.swift'),
          ),
      isEmpty,
    );
    final source = File(implementation).readAsStringSync();
    expect(source, isNot(contains('PatchMatchCuda')));
    expect(source, isNot(contains('cuda')));

    const androidClang =
        '/opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang++';
    expect(File(androidClang).existsSync(), isTrue);
    final syntax = await Process.run(androidClang, <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-fsyntax-only',
      '-I$sourceRoot',
      implementation,
    ]);
    expect(syntax.exitCode, 0, reason: '${syntax.stdout}\n${syntax.stderr}');
  });
}
