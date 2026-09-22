// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

// Host-only frozen-fixture helper. Source view selection is intentionally
// delegated unchanged to COLMAP's public MVS Model API; this program performs
// no geometric ranking or camera calculation of its own.

#include <colmap/mvs/model.h>
#include <colmap/sensor/bitmap.h>

#include <array>
#include <cerrno>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <type_traits>
#include <vector>

namespace {

struct Arguments {
  std::filesystem::path workspace;
  std::filesystem::path output;
  std::filesystem::path gray_pgm_directory;
  std::filesystem::path binary_packet_output;
  std::size_t max_source_images = 10U;
  double min_triangulation_angle = 1.0;
};

bool ParseUnsigned(const std::string &text, std::size_t *out) {
  if (out == nullptr || text.empty()) {
    return false;
  }
  char *end = nullptr;
  errno = 0;
  const unsigned long long value = std::strtoull(text.c_str(), &end, 10);
  if (errno != 0 || end == text.c_str() || *end != '\0') {
    return false;
  }
  *out = static_cast<std::size_t>(value);
  return true;
}

bool ParseDouble(const std::string &text, double *out) {
  if (out == nullptr || text.empty()) {
    return false;
  }
  char *end = nullptr;
  errno = 0;
  const double value = std::strtod(text.c_str(), &end);
  if (errno != 0 || end == text.c_str() || *end != '\0' || value <= 0.0) {
    return false;
  }
  *out = value;
  return true;
}

bool ParseArguments(int argc, char **argv, Arguments *out) {
  if (out == nullptr) {
    return false;
  }
  Arguments parsed;
  for (int i = 1; i < argc; ++i) {
    const std::string flag(argv[i]);
    if (i + 1 >= argc) {
      return false;
    }
    const std::string value(argv[++i]);
    if (flag == "--workspace") {
      parsed.workspace = value;
    } else if (flag == "--output") {
      parsed.output = value;
    } else if (flag == "--gray-pgm-directory") {
      parsed.gray_pgm_directory = value;
    } else if (flag == "--binary-packet-output") {
      parsed.binary_packet_output = value;
    } else if (flag == "--max-source-images") {
      if (!ParseUnsigned(value, &parsed.max_source_images)) {
        return false;
      }
    } else if (flag == "--min-triangulation-angle") {
      if (!ParseDouble(value, &parsed.min_triangulation_angle)) {
        return false;
      }
    } else {
      return false;
    }
  }
  if (parsed.workspace.empty() || parsed.output.empty()) {
    return false;
  }
  *out = parsed;
  return true;
}

void WriteJsonString(std::ostream &stream, const std::string &value) {
  stream << '"';
  for (const unsigned char character : value) {
    switch (character) {
      case '"':
        stream << "\\\"";
        break;
      case '\\':
        stream << "\\\\";
        break;
      case '\b':
        stream << "\\b";
        break;
      case '\f':
        stream << "\\f";
        break;
      case '\n':
        stream << "\\n";
        break;
      case '\r':
        stream << "\\r";
        break;
      case '\t':
        stream << "\\t";
        break;
      default:
        if (character < 0x20U) {
          stream << "\\u00" << std::hex << std::setw(2) << std::setfill('0')
                 << static_cast<unsigned int>(character) << std::dec
                 << std::setfill(' ');
        } else {
          stream << static_cast<char>(character);
        }
        break;
    }
  }
  stream << '"';
}

template <std::size_t kCount>
void WriteFloatArray(std::ostream &stream, const float *values) {
  stream << '[';
  for (std::size_t i = 0U; i < kCount; ++i) {
    if (i != 0U) {
      stream << ',';
    }
    stream << values[i];
  }
  stream << ']';
}

void WriteIntArray(std::ostream &stream, const std::vector<int> &values) {
  stream << '[';
  for (std::size_t i = 0U; i < values.size(); ++i) {
    if (i != 0U) {
      stream << ',';
    }
    stream << values[i];
  }
  stream << ']';
}

void WriteNameArray(std::ostream &stream,
                    const colmap::mvs::Model &model,
                    const std::vector<int> &source_indices) {
  stream << '[';
  for (std::size_t i = 0U; i < source_indices.size(); ++i) {
    if (i != 0U) {
      stream << ',';
    }
    WriteJsonString(stream, model.GetImageName(source_indices[i]));
  }
  stream << ']';
}

template <typename T>
bool WritePod(std::ofstream *stream, const T &value) {
  static_assert(std::is_trivially_copyable_v<T>);
  stream->write(reinterpret_cast<const char *>(&value), sizeof(value));
  return stream->good();
}

bool WriteScenePacket(
    const std::filesystem::path &path,
    const colmap::mvs::Model &model,
    const std::vector<std::vector<int>> &source_indices,
    const std::vector<std::pair<float, float>> &depth_ranges) {
  std::ofstream stream(path, std::ios::binary | std::ios::trunc);
  if (!stream.is_open()) return false;
  constexpr std::array<char, 8> kMagic = {
      'P', 'W', 'S', 'C', 'E', 'N', 'E', '1'};
  constexpr std::uint32_t kVersion = 1U;
  const std::uint32_t image_count =
      static_cast<std::uint32_t>(model.images.size());
  stream.write(kMagic.data(), static_cast<std::streamsize>(kMagic.size()));
  if (!WritePod(&stream, kVersion) || !WritePod(&stream, image_count)) {
    return false;
  }
  for (std::size_t index = 0U; index < model.images.size(); ++index) {
    const colmap::mvs::Image &image = model.images[index];
    const std::string image_name = model.GetImageName(static_cast<int>(index));
    const std::uint32_t name_size =
        static_cast<std::uint32_t>(image_name.size());
    const std::uint32_t source_count =
        static_cast<std::uint32_t>(source_indices[index].size());
    const std::uint32_t width = static_cast<std::uint32_t>(image.GetWidth());
    const std::uint32_t height = static_cast<std::uint32_t>(image.GetHeight());
    const std::uint32_t image_index = static_cast<std::uint32_t>(index);
    if (!WritePod(&stream, image_index) || !WritePod(&stream, width) ||
        !WritePod(&stream, height) || !WritePod(&stream, name_size) ||
        !WritePod(&stream, source_count)) {
      return false;
    }
    stream.write(image_name.data(), static_cast<std::streamsize>(name_size));
    stream.write(reinterpret_cast<const char *>(image.GetK()),
                 9 * static_cast<std::streamsize>(sizeof(float)));
    stream.write(reinterpret_cast<const char *>(image.GetR()),
                 9 * static_cast<std::streamsize>(sizeof(float)));
    stream.write(reinterpret_cast<const char *>(image.GetT()),
                 3 * static_cast<std::streamsize>(sizeof(float)));
    if (!WritePod(&stream, depth_ranges[index].first) ||
        !WritePod(&stream, depth_ranges[index].second)) {
      return false;
    }
    for (const int source_index : source_indices[index]) {
      const std::int32_t value = static_cast<std::int32_t>(source_index);
      if (!WritePod(&stream, value)) return false;
    }
    if (!stream.good()) return false;
  }
  return stream.good();
}

}  // namespace

int main(int argc, char **argv) {
  Arguments arguments;
  if (!ParseArguments(argc, argv, &arguments)) {
    std::cerr << "usage: " << argv[0]
      << " --workspace PATH --output PATH"
                 " [--gray-pgm-directory PATH]"
                 " [--binary-packet-output PATH]"
                 " [--max-source-images N]"
                 " [--min-triangulation-angle DEGREES]\n";
    return 2;
  }

  colmap::mvs::Model model;
  try {
    model.ReadFromCOLMAP(arguments.workspace);
  } catch (const std::exception &error) {
    std::cerr << "official COLMAP ReadFromCOLMAP failed: " << error.what()
              << '\n';
    return 1;
  }
  const std::vector<std::vector<int>> source_indices =
      model.GetMaxOverlappingImages(arguments.max_source_images,
                                    arguments.min_triangulation_angle);
  const std::vector<std::pair<float, float>> depth_ranges =
      model.ComputeDepthRanges();
  if (source_indices.size() != model.images.size() ||
      depth_ranges.size() != model.images.size()) {
    std::cerr << "official COLMAP returned an invalid source-view vector\n";
    return 1;
  }

  if (!arguments.gray_pgm_directory.empty()) {
    std::error_code error;
    std::filesystem::create_directories(arguments.gray_pgm_directory, error);
    if (error) {
      std::cerr << "cannot create gray PGM directory: "
                << arguments.gray_pgm_directory << '\n';
      return 1;
    }
  }
  if (!arguments.binary_packet_output.empty() &&
      !WriteScenePacket(arguments.binary_packet_output, model, source_indices,
                        depth_ranges)) {
    std::cerr << "cannot write frozen scene packet: "
              << arguments.binary_packet_output << '\n';
    return 1;
  }

  std::ofstream stream(arguments.output, std::ios::binary | std::ios::trunc);
  if (!stream.is_open()) {
    std::cerr << "cannot open output: " << arguments.output << '\n';
    return 1;
  }
  stream << std::setprecision(9);
  stream << "{\n  \"selection_api\": \"COLMAP mvs::Model::"
            "GetMaxOverlappingImages\",\n";
  stream << "  \"max_source_images\": " << arguments.max_source_images
         << ",\n";
  stream << "  \"min_triangulation_angle\": "
         << arguments.min_triangulation_angle << ",\n";
  stream << "  \"images\": [\n";
  for (std::size_t index = 0U; index < model.images.size(); ++index) {
    const colmap::mvs::Image &image = model.images[index];
    stream << "    {\"index\": " << index << ", \"name\": ";
    WriteJsonString(stream, model.GetImageName(static_cast<int>(index)));
    stream << ", \"width\": " << image.GetWidth()
           << ", \"height\": " << image.GetHeight() << ", \"K\": ";
    WriteFloatArray<9U>(stream, image.GetK());
    stream << ", \"R\": ";
    WriteFloatArray<9U>(stream, image.GetR());
    stream << ", \"T\": ";
    WriteFloatArray<3U>(stream, image.GetT());
    stream << ", \"depth_range\": [" << depth_ranges[index].first << ','
           << depth_ranges[index].second << ']';
    stream << ", \"source_indices\": ";
    WriteIntArray(stream, source_indices[index]);
    stream << ", \"source_names\": ";
    WriteNameArray(stream, model, source_indices[index]);
    if (!arguments.gray_pgm_directory.empty()) {
      const std::filesystem::path gray_name =
          std::filesystem::path(model.GetImageName(static_cast<int>(index)))
              .replace_extension(".pgm")
              .filename();
      colmap::Bitmap gray;
      if (!gray.Read(image.GetPath(), false) || !gray.IsGrey() ||
          gray.Width() != static_cast<int>(image.GetWidth()) ||
          gray.Height() != static_cast<int>(image.GetHeight()) ||
          !gray.Write(arguments.gray_pgm_directory / gray_name, false)) {
        std::cerr << "official COLMAP Bitmap read/write failed for "
                  << image.GetPath() << '\n';
        return 1;
      }
      stream << ", \"gray_pgm\": ";
      WriteJsonString(stream, gray_name.string());
    }
    stream << '}';
    if (index + 1U != model.images.size()) {
      stream << ',';
    }
    stream << '\n';
  }
  stream << "  ]\n}\n";
  if (!stream.good()) {
    std::cerr << "failed while writing output: " << arguments.output << '\n';
    return 1;
  }
  return 0;
}
