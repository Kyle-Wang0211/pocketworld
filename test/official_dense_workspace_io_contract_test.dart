import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const sourceRoot = 'vendor/official_dense/workspace_io';
  const implementation = '$sourceRoot/workspace_io.cc';

  test('COLMAP workspace I/O is byte-exact and fails closed', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'official_dense_workspace_io_',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final fixture = File('${temporary.path}/workspace_io_fixture.cc');
    await fixture.writeAsString(r'''
#include "workspace_io.h"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using pocketworld::official_dense::ConsistencyGraph;
using pocketworld::official_dense::FloatMatrix;
using pocketworld::official_dense::MaterializationEntry;

int Fail(const std::string& message) {
  std::cerr << message << std::endl;
  return 1;
}

std::string ReadText(const fs::path& path) {
  std::ifstream stream(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(stream),
                     std::istreambuf_iterator<char>());
}

int main(int argc, char** argv) {
  if (argc != 2) return Fail("missing fixture root");
  const fs::path root = argv[1];
  const auto workspace =
      pocketworld::official_dense::CreateStandardWorkspace(root);
  if (!workspace.ok()) return Fail(workspace.message);
  for (const auto& path : {
           root / "images",
           root / "sparse",
           root / "stereo",
           root / "stereo" / "depth_maps",
           root / "stereo" / "normal_maps",
           root / "stereo" / "consistency_graphs",
       }) {
    if (!fs::is_directory(path)) return Fail("missing standard directory");
  }

  const fs::path source = root / "source.jpg";
  {
    std::ofstream stream(source, std::ios::binary);
    stream << "abc";
  }
  const MaterializationEntry entry{
      source,
      "frame_000000.jpg",
      3,
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  };
  const auto materialized =
      pocketworld::official_dense::MaterializeImage(root / "images", entry);
  if (!materialized.ok()) return Fail(materialized.message);
  if (ReadText(root / "images" / entry.image_name) != "abc") {
    return Fail("materialized bytes differ");
  }
  if (pocketworld::official_dense::MaterializeImage(root / "images", entry)
          .ok()) {
    return Fail("overwriting an existing image was accepted");
  }
  MaterializationEntry escaping = entry;
  escaping.image_name = "../escape.jpg";
  if (pocketworld::official_dense::MaterializeImage(root / "images", escaping)
          .ok()) {
    return Fail("path traversal was accepted");
  }
  MaterializationEntry wrong_hash = entry;
  wrong_hash.image_name = "frame_000001.jpg";
  wrong_hash.sha256 = std::string(64, '0');
  if (pocketworld::official_dense::MaterializeImage(root / "images", wrong_hash)
          .ok()) {
    return Fail("hash mismatch was accepted");
  }
  if (fs::exists(root / "images" / wrong_hash.image_name)) {
    return Fail("failed materialization left destination behind");
  }
  const fs::path source_symlink = root / "source-link.jpg";
  fs::create_symlink(source, source_symlink);
  MaterializationEntry symlink_source = entry;
  symlink_source.source_path = source_symlink;
  symlink_source.image_name = "frame_000002.jpg";
  if (pocketworld::official_dense::MaterializeImage(root / "images",
                                                     symlink_source)
          .ok()) {
    return Fail("symlink source escaped the frozen handoff identity");
  }
  const fs::path images_symlink = root / "images-link";
  fs::create_directory_symlink(root / "images", images_symlink);
  MaterializationEntry symlink_directory = entry;
  symlink_directory.image_name = "frame_000003.jpg";
  if (pocketworld::official_dense::MaterializeImage(images_symlink,
                                                     symlink_directory)
          .ok()) {
    return Fail("symlink images directory was accepted");
  }

  const fs::path matrix_path = root / "stereo" / "depth_maps" / "a.bin";
  const FloatMatrix matrix{2, 1, 2, {1.0f, -2.5f, 3.25f, 4.0f}};
  auto status = pocketworld::official_dense::WriteFloatMatrix(matrix_path,
                                                               matrix);
  if (!status.ok()) return Fail(status.message);
  const std::string matrix_bytes = ReadText(matrix_path);
  if (matrix_bytes.rfind("2&1&2&", 0) != 0) {
    return Fail("matrix header differs from COLMAP");
  }
  const std::vector<unsigned char> expected_matrix_payload = {
      0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x20, 0xc0,
      0x00, 0x00, 0x50, 0x40, 0x00, 0x00, 0x80, 0x40,
  };
  if (matrix_bytes.size() != 6 + expected_matrix_payload.size()) {
    return Fail("matrix byte count differs from COLMAP");
  }
  for (std::size_t index = 0; index < expected_matrix_payload.size(); ++index) {
    if (static_cast<unsigned char>(matrix_bytes[6 + index]) !=
        expected_matrix_payload[index]) {
      return Fail("matrix float32 payload is not little-endian");
    }
  }
  FloatMatrix matrix_roundtrip;
  status = pocketworld::official_dense::ReadFloatMatrix(matrix_path,
                                                         &matrix_roundtrip);
  if (!status.ok()) return Fail(status.message);
  if (matrix_roundtrip.width != 2 || matrix_roundtrip.height != 1 ||
      matrix_roundtrip.depth != 2 || matrix_roundtrip.values != matrix.values) {
    return Fail("matrix round-trip differs");
  }
  {
    std::ofstream stream(matrix_path, std::ios::binary | std::ios::app);
    stream.put('\0');
  }
  if (pocketworld::official_dense::ReadFloatMatrix(matrix_path,
                                                    &matrix_roundtrip).ok()) {
    return Fail("float matrix trailing bytes were accepted");
  }

  const fs::path graph_path =
      root / "stereo" / "consistency_graphs" / "a.bin";
  const ConsistencyGraph graph{2, 1, {0, 0, 2, 4, 7, 1, 0, 0}};
  status = pocketworld::official_dense::WriteConsistencyGraph(graph_path,
                                                               graph);
  if (!status.ok()) return Fail(status.message);
  if (ReadText(graph_path).rfind("2&1&1&", 0) != 0) {
    return Fail("consistency graph header differs from COLMAP");
  }
  const std::string graph_bytes = ReadText(graph_path);
  if (graph_bytes.size() != 6 + graph.values.size() * 4 ||
      static_cast<unsigned char>(graph_bytes[14]) != 0x02 ||
      static_cast<unsigned char>(graph_bytes[15]) != 0x00 ||
      static_cast<unsigned char>(graph_bytes[16]) != 0x00 ||
      static_cast<unsigned char>(graph_bytes[17]) != 0x00) {
    return Fail("consistency graph int32 payload is not little-endian");
  }
  ConsistencyGraph graph_roundtrip;
  status = pocketworld::official_dense::ReadConsistencyGraph(graph_path,
                                                              &graph_roundtrip);
  if (!status.ok()) return Fail(status.message);
  if (graph_roundtrip.width != graph.width ||
      graph_roundtrip.height != graph.height ||
      graph_roundtrip.values != graph.values) {
    return Fail("consistency graph round-trip differs");
  }
  const fs::path wrong_depth_graph_path =
      root / "stereo" / "consistency_graphs" / "wrong_depth.bin";
  {
    std::ofstream stream(wrong_depth_graph_path, std::ios::binary);
    stream << "2&1&2&" << graph_bytes.substr(6);
  }
  if (pocketworld::official_dense::ReadConsistencyGraph(
          wrong_depth_graph_path, &graph_roundtrip).ok()) {
    return Fail("consistency graph depth other than one was accepted");
  }

  status = pocketworld::official_dense::WriteConfigLines(
      root / "stereo" / "patch-match.cfg", {"b.jpg", "a.jpg"});
  if (!status.ok()) return Fail(status.message);
  status = pocketworld::official_dense::WriteConfigLines(
      root / "stereo" / "fusion.cfg", {"a.jpg", "b.jpg"});
  if (!status.ok()) return Fail(status.message);
  if (ReadText(root / "stereo" / "patch-match.cfg") != "b.jpg\na.jpg\n") {
    return Fail("patch-match.cfg order changed");
  }
  if (ReadText(root / "stereo" / "fusion.cfg") != "a.jpg\nb.jpg\n") {
    return Fail("fusion.cfg order changed");
  }
  status = pocketworld::official_dense::WriteConfigLines(
      root / "stereo" / "patch-match.cfg", {});
  if (status.ok()) return Fail("empty automatic selection was accepted");

  for (const auto& entry : fs::directory_iterator(root / "images")) {
    if (entry.path().filename().string().find(".pwofficial.tmp.") !=
        std::string::npos) {
      return Fail("owned temporary file was not cleaned");
    }
  }
  return 0;
}
''');

    final executable = '${temporary.path}/workspace_io_fixture';
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

  test(
    'workspace I/O is C++17, Android syntax-clean, and contains no Swift',
    () async {
      final source = File(implementation).readAsStringSync();
      expect(source, isNot(contains('system(')));
      expect(source, isNot(contains('std::sort')));
      expect(source, contains('std::filesystem::rename'));
      expect(source, contains('std::filesystem::create_hard_link'));
      expect(source, contains('fs::copy_file'));

      final swiftFiles = Directory(sourceRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.swift'));
      expect(swiftFiles, isEmpty);

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
    },
  );
}
