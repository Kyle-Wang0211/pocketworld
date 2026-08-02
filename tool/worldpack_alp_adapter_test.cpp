#include "worldpack_alp_adapter.h"

#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

template <class UInt>
bool WriteWords(const std::filesystem::path& path,
                const std::vector<UInt>& words) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(reinterpret_cast<const char*>(words.data()),
               static_cast<std::streamsize>(words.size() * sizeof(UInt)));
  return output.good();
}

std::string Read(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

int Fail(const std::string& message) {
  std::cerr << "worldpack_alp_adapter_test: " << message << '\n';
  return 1;
}

template <class UInt>
int Exercise(const std::filesystem::path& scratch,
             const std::string& stem,
             const pw::worldpack::alp_codec::ElementType type,
             std::vector<UInt> words) {
  const auto input = scratch / (stem + ".raw");
  const auto archive = scratch / (stem + ".alp");
  const auto restored = scratch / (stem + ".restored");
  if (!WriteWords(input, words)) {
    return Fail("could not write " + stem + " input");
  }
  pw::worldpack::alp_codec::Result result;
  std::string error;
  if (!pw::worldpack::alp_codec::Run(type, input, archive, restored, &result,
                                     &error)) {
    return Fail(stem + " round trip failed: " + error);
  }
  if (Read(input) != Read(restored) || !result.byte_equal ||
      !result.corruption_rejected || result.input_bytes != Read(input).size() ||
      result.complete_persisted_bytes !=
          std::filesystem::file_size(archive) ||
      result.alp_vectors + result.alprd_vectors == 0) {
    return Fail(stem + " strict evidence is incomplete");
  }
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    return Fail("expected a task-owned scratch directory");
  }
  if (std::string(pw::worldpack::alp_codec::Revision()) !=
      "31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce") {
    return Fail("ALP source identity is not frozen");
  }
  std::vector<std::uint32_t> floats(1024);
  for (std::size_t index = 0; index < floats.size(); ++index) {
    const float value = static_cast<float>(index % 97) / 10.0F;
    std::memcpy(&floats[index], &value, sizeof(value));
  }
  floats[3] = 0x80000000U;  // -0.0
  floats[9] = 0x7fc12345U;  // NaN with a non-default payload
  floats[15] = 0xff800000U;  // -infinity
  if (const int failure =
          Exercise(argv[1], "float32", pw::worldpack::alp_codec::ElementType::kFloat32,
                   std::move(floats));
      failure != 0) {
    return failure;
  }

  std::vector<std::uint64_t> doubles(1024);
  for (std::size_t index = 0; index < doubles.size(); ++index) {
    const double value = static_cast<double>(index % 113) / 100.0;
    std::memcpy(&doubles[index], &value, sizeof(value));
  }
  doubles[2] = 0x8000000000000000ULL;  // -0.0
  doubles[8] = 0x7ff8123456789abcULL;  // NaN with a non-default payload
  doubles[14] = 0x7ff0000000000000ULL;  // +infinity
  if (const int failure =
          Exercise(argv[1], "float64", pw::worldpack::alp_codec::ElementType::kFloat64,
                   std::move(doubles));
      failure != 0) {
    return failure;
  }
  std::cout << "PW_WORLDPACK_ALP_ADAPTER_TESTS_OK\n";
  return 0;
}
