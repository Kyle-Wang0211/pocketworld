#include "worldpack_openzl_adapter.h"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

void Append32(std::string* output, const std::uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) {
    output->push_back(static_cast<char>((value >> shift) & 0xff));
  }
}

void AppendRecord(std::string* output,
                  const std::uint8_t element_width,
                  const std::uint32_t tag,
                  const std::string& payload) {
  Append32(output, static_cast<std::uint32_t>(payload.size()));
  output->push_back(static_cast<char>(element_width));
  Append32(output, tag);
  output->append(payload);
}

std::string Bundle(const int seed) {
  std::string roots(128, '\0');
  std::string residuals(256, '\0');
  for (std::size_t index = 0; index < roots.size(); ++index) {
    roots[index] = static_cast<char>((seed + index * 3) & 0xff);
  }
  for (std::size_t index = 0; index < residuals.size(); ++index) {
    residuals[index] = static_cast<char>((seed / 2 + index % 11) & 0xff);
  }
  std::string parents;
  Append32(&parents, 0xffffffffU);
  Append32(&parents, 0);
  Append32(&parents, 1);
  std::string output;
  AppendRecord(&output, 1, 1000, roots);
  AppendRecord(&output, 1, 1001, residuals);
  AppendRecord(&output, 4, 1002, parents);
  return output;
}

bool Write(const std::filesystem::path& path, const std::string& contents) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
  return output.good();
}

std::string Read(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

int Fail(const std::string& message) {
  std::cerr << "worldpack_openzl_adapter_test: " << message << '\n';
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    return Fail("expected a task-owned scratch directory");
  }
  if (std::string(pw::worldpack::openzl::Version()) != "0.2.0" ||
      std::string(pw::worldpack::openzl::Revision()) !=
          "3dceb64867840201fb8f57a29d179995f700c9b8") {
    return Fail("OpenZL source identity is not frozen");
  }

  std::size_t stream_count = 0;
  std::string error;
  const std::string test_bundle = Bundle(19);
  if (!pw::worldpack::openzl::ValidateTypedBundle(test_bundle, &stream_count,
                                                   &error) ||
      stream_count != 3) {
    return Fail("valid typed bundle was rejected: " + error);
  }
  std::string duplicate_tag_bundle;
  AppendRecord(&duplicate_tag_bundle, 1, 1000, "abc");
  AppendRecord(&duplicate_tag_bundle, 1, 1000, "def");
  if (pw::worldpack::openzl::ValidateTypedBundle(
          duplicate_tag_bundle, &stream_count, &error)) {
    return Fail("duplicate typed stream tag was accepted");
  }

  const std::filesystem::path scratch(argv[1]);
  const std::filesystem::path input = scratch / "test.bundle";
  const std::filesystem::path frame = scratch / "test.openzl";
  const std::filesystem::path model = scratch / "test.zc";
  const std::filesystem::path restored = scratch / "test.restored";
  if (!Write(input, test_bundle)) {
    return Fail("could not write test bundle");
  }
  pw::worldpack::openzl::Config config;
  config.mode = pw::worldpack::openzl::Mode::kUntrainedParser;
  config.test_path = input;
  config.frame_path = frame;
  config.encoder_model_path = model;
  config.restored_path = restored;
  config.training_threads = 1;
  pw::worldpack::openzl::Result result;
  if (!pw::worldpack::openzl::Run(config, &result, &error)) {
    return Fail("untrained parser round trip failed: " + error);
  }
  if (Read(restored) != test_bundle || !result.byte_equal ||
      !result.corruption_rejected || result.typed_data_streams != 3 ||
      result.frame_bytes != std::filesystem::file_size(frame) ||
      result.encoder_model_bytes != std::filesystem::file_size(model) ||
      result.decoder_dependency_bytes != 0 || result.training_completed) {
    return Fail("untrained parser evidence is incomplete");
  }

  std::cout << "PW_WORLDPACK_OPENZL_ADAPTER_TESTS_OK\n";
  return 0;
}

