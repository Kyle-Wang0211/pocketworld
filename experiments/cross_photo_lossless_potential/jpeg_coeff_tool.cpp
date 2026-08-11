#include <csetjmp>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" {
#include <jpeglib.h>
}

namespace {

constexpr char kMagic[] = "PWCJPEG1";
constexpr uint32_t kVersion = 1;
constexpr uint8_t kMarkerSoi = 0xd8;
constexpr uint8_t kMarkerSos = 0xda;
constexpr uint8_t kMarkerRst0 = 0xd0;
constexpr uint8_t kMarkerRst7 = 0xd7;

struct JpegError {
  jpeg_error_mgr base;
  std::jmp_buf jump;
  char message[JMSG_LENGTH_MAX] = {};
};

void OnJpegError(j_common_ptr info) {
  auto* error = reinterpret_cast<JpegError*>(info->err);
  (*info->err->format_message)(info, error->message);
  std::longjmp(error->jump, 1);
}

std::vector<uint8_t> ReadFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    throw std::runtime_error("cannot open input: " + path.string());
  }
  const auto end = input.tellg();
  if (end < 0) {
    throw std::runtime_error("cannot size input: " + path.string());
  }
  std::vector<uint8_t> data(static_cast<size_t>(end));
  input.seekg(0);
  if (!data.empty() &&
      !input.read(reinterpret_cast<char*>(data.data()),
                  static_cast<std::streamsize>(data.size()))) {
    throw std::runtime_error("cannot read input: " + path.string());
  }
  return data;
}

void WriteFile(const std::filesystem::path& path,
               const std::vector<uint8_t>& data) {
  const auto temporary = path.string() + ".tmp";
  std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
  if (!output ||
      (!data.empty() &&
       !output.write(reinterpret_cast<const char*>(data.data()),
                     static_cast<std::streamsize>(data.size())))) {
    std::filesystem::remove(temporary);
    throw std::runtime_error("cannot write output: " + path.string());
  }
  output.close();
  if (!output) {
    std::filesystem::remove(temporary);
    throw std::runtime_error("cannot close output: " + path.string());
  }
  std::filesystem::rename(temporary, path);
}

size_t ScanStart(const std::vector<uint8_t>& jpeg) {
  if (jpeg.size() < 4 || jpeg[0] != 0xff || jpeg[1] != kMarkerSoi) {
    throw std::runtime_error("invalid JPEG SOI");
  }
  size_t offset = 2;
  while (offset + 4 <= jpeg.size()) {
    if (jpeg[offset] != 0xff) {
      throw std::runtime_error("invalid JPEG marker alignment");
    }
    while (offset < jpeg.size() && jpeg[offset] == 0xff) {
      ++offset;
    }
    if (offset >= jpeg.size()) {
      break;
    }
    const uint8_t marker = jpeg[offset++];
    if (marker == JPEG_EOI) {
      throw std::runtime_error("JPEG ended before SOS");
    }
    if (marker == kMarkerSoi ||
        (marker >= kMarkerRst0 && marker <= kMarkerRst7)) {
      continue;
    }
    if (offset + 2 > jpeg.size()) {
      throw std::runtime_error("truncated JPEG marker length");
    }
    const size_t length =
        (static_cast<size_t>(jpeg[offset]) << 8) | jpeg[offset + 1];
    if (length < 2 || offset + length > jpeg.size()) {
      throw std::runtime_error("invalid JPEG marker length");
    }
    offset += length;
    if (marker == kMarkerSos) {
      return offset;
    }
  }
  throw std::runtime_error("JPEG SOS is missing");
}

size_t ScanEnd(const std::vector<uint8_t>& jpeg, size_t scan_start) {
  if (jpeg.size() < scan_start + 2 || jpeg[jpeg.size() - 2] != 0xff ||
      jpeg[jpeg.size() - 1] != JPEG_EOI) {
    throw std::runtime_error("JPEG EOI is missing");
  }
  return jpeg.size() - 2;
}

void AppendU32(std::vector<uint8_t>* output, uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) {
    output->push_back(static_cast<uint8_t>(value >> shift));
  }
}

void AppendU64(std::vector<uint8_t>* output, uint64_t value) {
  for (int shift = 0; shift < 64; shift += 8) {
    output->push_back(static_cast<uint8_t>(value >> shift));
  }
}

void AppendI16(std::vector<uint8_t>* output, int16_t value) {
  const uint16_t encoded = static_cast<uint16_t>(value);
  output->push_back(static_cast<uint8_t>(encoded));
  output->push_back(static_cast<uint8_t>(encoded >> 8));
}

class Reader {
 public:
  explicit Reader(const std::vector<uint8_t>& data) : data_(data) {}

  void RequireMagic() {
    Require(sizeof(kMagic) - 1);
    if (std::memcmp(data_.data() + offset_, kMagic, sizeof(kMagic) - 1) != 0) {
      throw std::runtime_error("coefficient container magic mismatch");
    }
    offset_ += sizeof(kMagic) - 1;
  }

  uint32_t U32() {
    Require(4);
    uint32_t value = 0;
    for (int shift = 0; shift < 32; shift += 8) {
      value |= static_cast<uint32_t>(data_[offset_++]) << shift;
    }
    return value;
  }

  uint64_t U64() {
    Require(8);
    uint64_t value = 0;
    for (int shift = 0; shift < 64; shift += 8) {
      value |= static_cast<uint64_t>(data_[offset_++]) << shift;
    }
    return value;
  }

  int16_t I16() {
    Require(2);
    const uint16_t value = static_cast<uint16_t>(data_[offset_]) |
                           (static_cast<uint16_t>(data_[offset_ + 1]) << 8);
    offset_ += 2;
    return static_cast<int16_t>(value);
  }

  std::vector<uint8_t> Bytes(size_t size) {
    Require(size);
    std::vector<uint8_t> result(data_.begin() + offset_,
                                data_.begin() + offset_ + size);
    offset_ += size;
    return result;
  }

  void RequireEnd() const {
    if (offset_ != data_.size()) {
      throw std::runtime_error("coefficient container has trailing bytes");
    }
  }

 private:
  void Require(size_t size) const {
    if (size > data_.size() - offset_) {
      throw std::runtime_error("truncated coefficient container");
    }
  }

  const std::vector<uint8_t>& data_;
  size_t offset_ = 0;
};

struct Component {
  uint32_t width_blocks = 0;
  uint32_t height_blocks = 0;
  std::vector<int16_t> coefficients;
};

struct Container {
  uint32_t restart_interval = 0;
  std::vector<uint8_t> header;
  std::vector<Component> components;
};

std::vector<uint8_t> Serialize(const Container& container) {
  std::vector<uint8_t> output;
  output.insert(output.end(), kMagic, kMagic + sizeof(kMagic) - 1);
  AppendU32(&output, kVersion);
  AppendU32(&output, container.restart_interval);
  AppendU32(&output, static_cast<uint32_t>(container.components.size()));
  AppendU64(&output, container.header.size());
  for (const auto& component : container.components) {
    AppendU32(&output, component.width_blocks);
    AppendU32(&output, component.height_blocks);
    AppendU64(&output, component.coefficients.size());
  }
  output.insert(output.end(), container.header.begin(), container.header.end());
  for (const auto& component : container.components) {
    for (const int16_t value : component.coefficients) {
      AppendI16(&output, value);
    }
  }
  return output;
}

Container Parse(const std::vector<uint8_t>& data) {
  Reader reader(data);
  reader.RequireMagic();
  if (reader.U32() != kVersion) {
    throw std::runtime_error("unsupported coefficient container version");
  }
  Container container;
  container.restart_interval = reader.U32();
  const uint32_t component_count = reader.U32();
  const uint64_t header_size = reader.U64();
  if (component_count == 0 || component_count > MAX_COMPONENTS ||
      header_size > data.size()) {
    throw std::runtime_error("invalid coefficient container dimensions");
  }
  std::vector<uint64_t> coefficient_counts;
  for (uint32_t index = 0; index < component_count; ++index) {
    Component component;
    component.width_blocks = reader.U32();
    component.height_blocks = reader.U32();
    const uint64_t count = reader.U64();
    if (component.width_blocks == 0 || component.height_blocks == 0 ||
        count != static_cast<uint64_t>(component.width_blocks) *
                     component.height_blocks * DCTSIZE2 ||
        count > data.size() / sizeof(int16_t)) {
      throw std::runtime_error("invalid coefficient component dimensions");
    }
    coefficient_counts.push_back(count);
    container.components.push_back(std::move(component));
  }
  container.header = reader.Bytes(static_cast<size_t>(header_size));
  for (size_t index = 0; index < container.components.size(); ++index) {
    auto& coefficients = container.components[index].coefficients;
    coefficients.reserve(static_cast<size_t>(coefficient_counts[index]));
    for (uint64_t item = 0; item < coefficient_counts[index]; ++item) {
      coefficients.push_back(reader.I16());
    }
  }
  reader.RequireEnd();
  return container;
}

Container Extract(const std::vector<uint8_t>& jpeg) {
  jpeg_decompress_struct source = {};
  JpegError error = {};
  source.err = jpeg_std_error(&error.base);
  error.base.error_exit = OnJpegError;
  if (setjmp(error.jump)) {
    jpeg_destroy_decompress(&source);
    throw std::runtime_error(std::string("libjpeg extract failed: ") +
                             error.message);
  }
  jpeg_create_decompress(&source);
  jpeg_mem_src(&source, jpeg.data(), jpeg.size());
  if (jpeg_read_header(&source, TRUE) != JPEG_HEADER_OK ||
      source.progressive_mode) {
    jpeg_destroy_decompress(&source);
    throw std::runtime_error("unsupported JPEG header");
  }
  jvirt_barray_ptr* arrays = jpeg_read_coefficients(&source);
  if (arrays == nullptr) {
    jpeg_destroy_decompress(&source);
    throw std::runtime_error("libjpeg coefficient extraction suspended");
  }

  Container container;
  container.restart_interval = source.restart_interval;
  const size_t scan_start = ScanStart(jpeg);
  container.header.assign(jpeg.begin(), jpeg.begin() + scan_start);
  for (int component_index = 0; component_index < source.num_components;
       ++component_index) {
    const jpeg_component_info& info = source.comp_info[component_index];
    Component component;
    component.width_blocks = info.width_in_blocks;
    component.height_blocks = info.height_in_blocks;
    component.coefficients.reserve(
        static_cast<size_t>(info.width_in_blocks) * info.height_in_blocks *
        DCTSIZE2);
    for (JDIMENSION row = 0; row < info.height_in_blocks; ++row) {
      JBLOCKARRAY block_row = (*source.mem->access_virt_barray)(
          reinterpret_cast<j_common_ptr>(&source), arrays[component_index], row,
          1, FALSE);
      for (JDIMENSION column = 0; column < info.width_in_blocks; ++column) {
        for (int coefficient = 0; coefficient < DCTSIZE2; ++coefficient) {
          component.coefficients.push_back(
              static_cast<int16_t>(block_row[0][column][coefficient]));
        }
      }
    }
    container.components.push_back(std::move(component));
  }
  jpeg_destroy_decompress(&source);
  return container;
}

std::vector<uint8_t> Restore(const Container& container) {
  if (container.header.size() < 4) {
    throw std::runtime_error("stored JPEG header is too short");
  }
  std::vector<uint8_t> header_input = container.header;
  header_input.push_back(0xff);
  header_input.push_back(JPEG_EOI);

  jpeg_decompress_struct source = {};
  jpeg_compress_struct destination = {};
  JpegError source_error = {};
  JpegError destination_error = {};
  unsigned char* generated_data = nullptr;
  unsigned long generated_size = 0;

  source.err = jpeg_std_error(&source_error.base);
  source_error.base.error_exit = OnJpegError;
  if (setjmp(source_error.jump)) {
    jpeg_destroy_decompress(&source);
    throw std::runtime_error(std::string("libjpeg header parse failed: ") +
                             source_error.message);
  }
  jpeg_create_decompress(&source);
  jpeg_mem_src(&source, header_input.data(), header_input.size());
  if (jpeg_read_header(&source, TRUE) != JPEG_HEADER_OK ||
      source.progressive_mode ||
      static_cast<size_t>(source.num_components) !=
          container.components.size()) {
    jpeg_destroy_decompress(&source);
    throw std::runtime_error("stored JPEG header is incompatible");
  }
  jpeg_calc_output_dimensions(&source);

  destination.err = jpeg_std_error(&destination_error.base);
  destination_error.base.error_exit = OnJpegError;
  if (setjmp(destination_error.jump)) {
    if (generated_data != nullptr) {
      std::free(generated_data);
    }
    jpeg_destroy_compress(&destination);
    jpeg_destroy_decompress(&source);
    throw std::runtime_error(std::string("libjpeg restore failed: ") +
                             destination_error.message);
  }
  jpeg_create_compress(&destination);
  jpeg_mem_dest(&destination, &generated_data, &generated_size);
  jpeg_copy_critical_parameters(&source, &destination);
  destination.restart_interval = container.restart_interval;
  if (destination.image_width == 0 || destination.image_height == 0) {
    throw std::runtime_error(
        "critical JPEG dimensions missing: source=" +
        std::to_string(source.image_width) + "x" +
        std::to_string(source.image_height) + ", destination=" +
        std::to_string(destination.image_width) + "x" +
        std::to_string(destination.image_height));
  }

  auto** arrays = reinterpret_cast<jvirt_barray_ptr*>(
      (*destination.mem->alloc_small)(
          reinterpret_cast<j_common_ptr>(&destination), JPOOL_IMAGE,
          sizeof(jvirt_barray_ptr) * destination.num_components));
  for (int index = 0; index < destination.num_components; ++index) {
    const auto& stored = container.components[index];
    const auto& info = destination.comp_info[index];
    arrays[index] = (*destination.mem->request_virt_barray)(
        reinterpret_cast<j_common_ptr>(&destination), JPOOL_IMAGE, TRUE,
        stored.width_blocks, stored.height_blocks, info.v_samp_factor);
  }
  jpeg_write_coefficients(&destination, arrays);
  for (int index = 0; index < destination.num_components; ++index) {
    const auto& stored = container.components[index];
    const auto& info = destination.comp_info[index];
    if (stored.width_blocks != info.width_in_blocks ||
        stored.height_blocks != info.height_in_blocks) {
      jpeg_destroy_compress(&destination);
      jpeg_destroy_decompress(&source);
      throw std::runtime_error("stored coefficient dimensions mismatch header");
    }
    size_t offset = 0;
    for (JDIMENSION row = 0; row < stored.height_blocks; ++row) {
      JBLOCKARRAY block_row = (*destination.mem->access_virt_barray)(
          reinterpret_cast<j_common_ptr>(&destination), arrays[index], row, 1,
          TRUE);
      for (JDIMENSION column = 0; column < stored.width_blocks; ++column) {
        for (int coefficient = 0; coefficient < DCTSIZE2; ++coefficient) {
          block_row[0][column][coefficient] =
              stored.coefficients[offset++];
        }
      }
    }
  }
  jpeg_finish_compress(&destination);
  std::vector<uint8_t> generated(generated_data,
                                 generated_data + generated_size);
  std::free(generated_data);
  generated_data = nullptr;
  jpeg_destroy_compress(&destination);
  jpeg_destroy_decompress(&source);

  const size_t generated_scan_start = ScanStart(generated);
  const size_t generated_scan_end =
      ScanEnd(generated, generated_scan_start);
  std::vector<uint8_t> restored = container.header;
  restored.insert(restored.end(), generated.begin() + generated_scan_start,
                  generated.begin() + generated_scan_end);
  restored.push_back(0xff);
  restored.push_back(JPEG_EOI);
  return restored;
}

int Run(int argc, char** argv) {
  if (argc != 4) {
    throw std::runtime_error(
        "usage: jpeg_coeff_tool extract|restore INPUT OUTPUT");
  }
  const std::string command = argv[1];
  if (command == "extract") {
    WriteFile(argv[3], Serialize(Extract(ReadFile(argv[2]))));
    return 0;
  }
  if (command == "restore") {
    WriteFile(argv[3], Restore(Parse(ReadFile(argv[2]))));
    return 0;
  }
  throw std::runtime_error("unknown command: " + command);
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return Run(argc, argv);
  } catch (const std::exception& error) {
    std::fprintf(stderr, "PW_JPEG_COEFF_ERROR: %s\n", error.what());
    return 1;
  }
}
