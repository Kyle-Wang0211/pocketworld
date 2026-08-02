#include "worldpack_zpaq_adapter.h"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

bool Write(const std::filesystem::path& path,
           const std::vector<std::uint8_t>& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  return output.good();
}

std::vector<std::uint8_t> Read(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(input),
                                   std::istreambuf_iterator<char>());
}

int Fail(const std::string& message) {
  std::cerr << "worldpack_zpaq_adapter_test: " << message << '\n';
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    return Fail("expected a task-owned scratch directory");
  }
  const std::filesystem::path scratch(argv[1]);
  const std::filesystem::path input = scratch / "input.bin";
  const std::filesystem::path archive = scratch / "archive.zpaq";
  const std::filesystem::path restored = scratch / "restored.bin";
  std::vector<std::uint8_t> payload;
  payload.reserve(800000);
  for (std::uint32_t index = 0; index < 200000; ++index) {
    payload.push_back(static_cast<std::uint8_t>((index / 97) & 0xff));
    payload.push_back(static_cast<std::uint8_t>(index & 0x07));
    payload.push_back(0);
    payload.push_back(0);
  }
  if (!Write(input, payload)) {
    return Fail("could not write input");
  }

  if (std::string(pw::worldpack::zpaq::Version()) != "7.15" ||
      std::string(pw::worldpack::zpaq::SourceSha256()) !=
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") {
    return Fail("ZPAQ source identity is not frozen");
  }
  pw::worldpack::zpaq::Result compressed;
  std::string error;
  if (!pw::worldpack::zpaq::CompressFile(input, archive, 5, &compressed,
                                         &error)) {
    return Fail("compression failed: " + error);
  }
  if (compressed.input_bytes != payload.size() ||
      compressed.complete_persisted_bytes !=
          std::filesystem::file_size(archive) ||
      compressed.complete_persisted_bytes == 0) {
    return Fail("compression byte accounting is incomplete");
  }

  pw::worldpack::zpaq::Result decompressed;
  if (!pw::worldpack::zpaq::DecompressFile(archive, restored, &decompressed,
                                          &error) ||
      Read(restored) != payload) {
    return Fail("decompression was not byte-exact: " + error);
  }
  if (decompressed.input_bytes != std::filesystem::file_size(archive) ||
      decompressed.complete_persisted_bytes != payload.size()) {
    return Fail("decompression byte accounting is incomplete");
  }

  pw::worldpack::zpaq::Result rejected;
  if (pw::worldpack::zpaq::CompressFile(input, scratch / "bad-method", 4,
                                        &rejected, &error) ||
      std::filesystem::exists(scratch / "bad-method")) {
    return Fail("unsupported method was not rejected");
  }

  const std::filesystem::path sentinel = scratch / "existing-output.bin";
  const std::vector<std::uint8_t> sentinel_bytes = {1, 3, 3, 7};
  if (!Write(sentinel, sentinel_bytes) ||
      pw::worldpack::zpaq::DecompressFile(scratch / "missing.zpaq", sentinel,
                                         &rejected, &error) ||
      Read(sentinel) != sentinel_bytes) {
    return Fail("failed operation modified a pre-existing output");
  }

  std::vector<std::uint8_t> corrupt = Read(archive);
  corrupt[corrupt.size() / 2] ^= 0x80;
  const std::filesystem::path corrupt_archive = scratch / "corrupt.zpaq";
  const std::filesystem::path corrupt_output = scratch / "corrupt.out";
  if (!Write(corrupt_archive, corrupt)) {
    return Fail("could not write corrupt fixture");
  }
  if (pw::worldpack::zpaq::DecompressFile(corrupt_archive, corrupt_output,
                                         &rejected, &error) ||
      std::filesystem::exists(corrupt_output)) {
    return Fail("corrupt archive did not fail closed");
  }

  std::cout << "PW_WORLDPACK_ZPAQ_ADAPTER_TESTS_OK\n";
  return 0;
}
