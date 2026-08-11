#include "pwa2_official_codec_backend.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

int Fail(const std::string& message) {
  std::fprintf(stderr, "PW_PWA2_OFFICIAL_CODEC_TEST_FAILED: %s\n",
               message.c_str());
  return 1;
}

std::vector<std::uint8_t> U32Fixture() {
  std::vector<std::uint8_t> bytes;
  for (std::uint32_t index = 0; index < 4096; ++index) {
    const std::uint32_t value = index * 3 + index / 17;
    for (int shift = 0; shift < 32; shift += 8) {
      bytes.push_back(static_cast<std::uint8_t>(value >> shift));
    }
  }
  return bytes;
}

std::vector<std::uint8_t> F32Fixture() {
  std::vector<std::uint8_t> bytes;
  for (std::uint32_t index = 0; index < 4096; ++index) {
    const float value = static_cast<float>(index) * 0.125F - 31.0F;
    std::array<std::uint8_t, sizeof(value)> bits{};
    std::memcpy(bits.data(), &value, sizeof(value));
    bytes.insert(bytes.end(), bits.begin(), bits.end());
  }
  return bytes;
}

std::vector<std::uint8_t> U8Fixture() {
  std::vector<std::uint8_t> bytes(32768);
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    bytes[index] = static_cast<std::uint8_t>((index / 128) + index * 13);
  }
  return bytes;
}

bool RoundTrip(pw::codecbench::Codec codec,
               pw::codecbench::ScalarType scalar_type,
               std::size_t width,
               const std::vector<std::uint8_t>& input,
               std::string* error) {
  pw::codecbench::Parameters parameters;
  parameters.level = codec == pw::codecbench::Codec::kPcodec ? 12 : 9;
  parameters.element_width = width;
  pw::codecbench::Encoded encoded;
  if (!pw::codecbench::Encode(codec, scalar_type, parameters, input, &encoded,
                              error)) {
    return false;
  }
  std::vector<std::uint8_t> decoded;
  if (!pw::codecbench::Decode(encoded, &decoded, error) || decoded != input) {
    return false;
  }

  if (encoded.bytes.empty()) {
    *error = "codec returned an empty payload";
    return false;
  }
  encoded.bytes[encoded.bytes.size() / 2] ^= 0x01;
  decoded.clear();
  if (pw::codecbench::Decode(encoded, &decoded, error)) {
    *error = "corrupted payload passed SHA-256 verification";
    return false;
  }
  error->clear();
  return true;
}

}  // namespace

int main() {
  std::string error;
  if (!RoundTrip(pw::codecbench::Codec::kPcodec,
                 pw::codecbench::ScalarType::kU32, 4, U32Fixture(), &error) ||
      !RoundTrip(pw::codecbench::Codec::kPcodec,
                 pw::codecbench::ScalarType::kF32, 4, F32Fixture(), &error) ||
      !RoundTrip(pw::codecbench::Codec::kBlosc2,
                 pw::codecbench::ScalarType::kU8, 128, U8Fixture(), &error) ||
      !RoundTrip(pw::codecbench::Codec::kOpenZl,
                 pw::codecbench::ScalarType::kU8, 1, U8Fixture(), &error)) {
    return Fail(error);
  }
  std::printf("PW_PWA2_OFFICIAL_CODEC_TEST_OK\n");
  return 0;
}
