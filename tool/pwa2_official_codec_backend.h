#ifndef POCKETWORLD_TOOL_PWA2_OFFICIAL_CODEC_BACKEND_H_
#define POCKETWORLD_TOOL_PWA2_OFFICIAL_CODEC_BACKEND_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pw::codecbench {

enum class Codec : std::uint8_t {
  kPcodec = 1,
  kBlosc2 = 2,
  kOpenZl = 3,
};

enum class ScalarType : std::uint8_t {
  kU8 = 1,
  kU32 = 2,
  kF32 = 3,
};

struct Parameters {
  int level = 0;
  std::size_t element_width = 1;
  int filter = 0;
};

struct Encoded {
  Codec codec = Codec::kPcodec;
  ScalarType scalar_type = ScalarType::kU8;
  Parameters parameters;
  std::size_t element_count = 0;
  std::size_t raw_size = 0;
  std::array<std::uint8_t, 32> raw_sha256{};
  std::vector<std::uint8_t> bytes;
};

bool Encode(Codec codec,
            ScalarType scalar_type,
            const Parameters& parameters,
            const std::vector<std::uint8_t>& raw,
            Encoded* encoded,
            std::string* error);

bool Decode(const Encoded& encoded,
            std::vector<std::uint8_t>* raw,
            std::string* error);

const char* CodecName(Codec codec);

}  // namespace pw::codecbench

#endif  // POCKETWORLD_TOOL_PWA2_OFFICIAL_CODEC_BACKEND_H_
