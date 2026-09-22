// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "frozen_scene_loader.h"

#include <array>
#include <cerrno>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <string>
#include <type_traits>

namespace pocketworld::official_dense::vulkan {
namespace {

constexpr std::array<char, 8> kPacketMagic = {
    'P', 'W', 'S', 'C', 'E', 'N', 'E', '1'};
constexpr std::uint32_t kPacketVersion = 1U;
constexpr std::uint32_t kMaximumImages = 4096U;
constexpr std::uint32_t kMaximumNameBytes = 4096U;
constexpr std::uint32_t kMaximumSources = 1024U;

bool SetDetail(std::string* detail, const char* message) noexcept {
  if (detail != nullptr) *detail = message;
  return false;
}

template <typename T>
bool ReadPod(std::ifstream* stream, T* out) noexcept {
  static_assert(std::is_trivially_copyable_v<T>);
  stream->read(reinterpret_cast<char*>(out), sizeof(T));
  return static_cast<bool>(*stream);
}

bool ReadBytes(std::ifstream* stream,
               char* destination,
               const std::size_t size) noexcept {
  stream->read(destination, static_cast<std::streamsize>(size));
  return static_cast<bool>(*stream);
}

bool IsSafeImageName(const std::string& value) noexcept {
  if (value.empty() || value.size() > kMaximumNameBytes ||
      value.find('\0') != std::string::npos ||
      value.find('/') != std::string::npos ||
      value.find('\\') != std::string::npos) {
    return false;
  }
  return std::filesystem::path(value).filename() ==
         std::filesystem::path(value);
}

bool ReadToken(std::ifstream* stream, std::string* out) noexcept {
  std::string token;
  char character = 0;
  while (stream->get(character)) {
    if (character == '#') {
      while (stream->get(character) && character != '\n') {
      }
      continue;
    }
    if (character != ' ' && character != '\t' && character != '\r' &&
        character != '\n') {
      token.push_back(character);
      break;
    }
  }
  if (token.empty()) return false;
  while (stream->get(character)) {
    if (character == ' ' || character == '\t' || character == '\r' ||
        character == '\n') {
      *out = std::move(token);
      return true;
    }
    if (token.size() >= 32U) return false;
    token.push_back(character);
  }
  return false;
}

bool ParseDimension(const std::string& text, std::uint32_t* out) noexcept {
  if (out == nullptr || text.empty()) return false;
  char* end = nullptr;
  errno = 0;
  const unsigned long value = std::strtoul(text.c_str(), &end, 10);
  if (errno != 0 || end == text.c_str() || *end != '\0' || value == 0U ||
      value > std::numeric_limits<std::uint32_t>::max()) {
    return false;
  }
  *out = static_cast<std::uint32_t>(value);
  return true;
}

}  // namespace

bool LoadFrozenScene(const std::filesystem::path& packet_path,
                     FrozenScene* const out,
                     std::string* const detail) noexcept {
  if (out == nullptr) return SetDetail(detail, "null frozen scene output");
  try {
    std::ifstream stream(packet_path, std::ios::binary);
    if (!stream) return SetDetail(detail, "cannot open frozen scene packet");
    std::array<char, kPacketMagic.size()> magic{};
    if (!ReadBytes(&stream, magic.data(), magic.size()) || magic != kPacketMagic) {
      return SetDetail(detail, "invalid frozen scene packet magic");
    }
    std::uint32_t version = 0U;
    std::uint32_t image_count = 0U;
    if (!ReadPod(&stream, &version) || !ReadPod(&stream, &image_count) ||
        version != kPacketVersion || image_count == 0U ||
        image_count > kMaximumImages) {
      return SetDetail(detail, "invalid frozen scene packet header");
    }
    FrozenScene candidate;
    candidate.images.reserve(image_count);
    for (std::uint32_t item = 0U; item < image_count; ++item) {
      FrozenSceneImage image;
      std::uint32_t name_size = 0U;
      std::uint32_t source_count = 0U;
      if (!ReadPod(&stream, &image.index) || !ReadPod(&stream, &image.width) ||
          !ReadPod(&stream, &image.height) || !ReadPod(&stream, &name_size) ||
          !ReadPod(&stream, &source_count) || image.index != item ||
          image.width == 0U || image.height == 0U || name_size == 0U ||
          name_size > kMaximumNameBytes || source_count == 0U ||
          source_count > kMaximumSources) {
        return SetDetail(detail, "invalid frozen scene image header");
      }
      image.image_name.resize(name_size);
      if (!ReadBytes(&stream, image.image_name.data(), image.image_name.size()) ||
          !ReadBytes(&stream, reinterpret_cast<char*>(image.K.data()),
                     image.K.size() * sizeof(float)) ||
          !ReadBytes(&stream, reinterpret_cast<char*>(image.R.data()),
                     image.R.size() * sizeof(float)) ||
          !ReadBytes(&stream, reinterpret_cast<char*>(image.T.data()),
                     image.T.size() * sizeof(float)) ||
          !ReadPod(&stream, &image.depth_min) ||
          !ReadPod(&stream, &image.depth_max) ||
          !IsSafeImageName(image.image_name) || !(image.depth_min > 0.0F) ||
          !(image.depth_max >= image.depth_min)) {
        return SetDetail(detail, "invalid frozen scene image payload");
      }
      image.source_indices.resize(source_count);
      for (std::int32_t& source_index : image.source_indices) {
        if (!ReadPod(&stream, &source_index) || source_index < 0 ||
            static_cast<std::uint32_t>(source_index) >= image_count) {
          return SetDetail(detail, "invalid frozen scene source index");
        }
      }
      candidate.images.push_back(std::move(image));
    }
    char trailing = 0;
    if (stream.get(trailing)) {
      return SetDetail(detail, "unexpected frozen scene packet trailing bytes");
    }
    if (!stream.eof()) return SetDetail(detail, "cannot read frozen scene packet");
    *out = std::move(candidate);
    if (detail != nullptr) detail->clear();
    return true;
  } catch (...) {
    return SetDetail(detail, "frozen scene packet parsing threw");
  }
}

bool LoadFrozenGrayPgm(const std::filesystem::path& path,
                       const std::uint32_t expected_width,
                       const std::uint32_t expected_height,
                       std::vector<std::uint8_t>* const out,
                       std::string* const detail) noexcept {
  if (out == nullptr || expected_width == 0U || expected_height == 0U) {
    return SetDetail(detail, "invalid frozen PGM request");
  }
  try {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return SetDetail(detail, "cannot open frozen PGM");
    std::array<std::string, 3> tokens;
    for (std::string& token : tokens) {
      if (!ReadToken(&stream, &token)) {
        return SetDetail(detail, "invalid frozen PGM header");
      }
    }
    std::uint32_t width = 0U;
    std::uint32_t height = 0U;
    std::uint32_t maximum = 0U;
    if (tokens[0] != "P5" || !ParseDimension(tokens[1], &width) ||
        !ParseDimension(tokens[2], &height)) {
      return SetDetail(detail, "invalid frozen PGM dimensions");
    }
    std::string maximum_token;
    if (!ReadToken(&stream, &maximum_token) ||
        !ParseDimension(maximum_token, &maximum) || maximum != 255U ||
        width != expected_width || height != expected_height ||
        width > std::numeric_limits<std::size_t>::max() / height) {
      return SetDetail(detail, "frozen PGM does not match the COLMAP fixture");
    }
    std::vector<std::uint8_t> candidate(
        static_cast<std::size_t>(width) * static_cast<std::size_t>(height));
    stream.read(reinterpret_cast<char*>(candidate.data()),
                static_cast<std::streamsize>(candidate.size()));
    if (!stream || stream.get() != std::char_traits<char>::eof()) {
      return SetDetail(detail, "invalid frozen PGM payload");
    }
    *out = std::move(candidate);
    if (detail != nullptr) detail->clear();
    return true;
  } catch (...) {
    return SetDetail(detail, "frozen PGM parsing threw");
  }
}

}  // namespace pocketworld::official_dense::vulkan
