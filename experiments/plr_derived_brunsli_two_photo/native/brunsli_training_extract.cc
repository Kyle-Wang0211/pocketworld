#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include <brunsli/jpeg_data.h>
#include <brunsli/jpeg_data_reader.h>

namespace {

constexpr std::array<uint8_t, 8> kMagic = {'P', 'W', 'T', 'J', '1', 0, 0, 0};
constexpr size_t kDigestBytes = CC_SHA256_DIGEST_LENGTH;

std::array<uint8_t, kDigestBytes> Sha256(const std::vector<uint8_t>& bytes) {
  std::array<uint8_t, kDigestBytes> digest{};
  const void* data = bytes.empty() ? static_cast<const void*>("") : bytes.data();
  CC_SHA256(data, static_cast<CC_LONG>(bytes.size()), digest.data());
  return digest;
}

std::string HexDigest(const std::array<uint8_t, kDigestBytes>& digest) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (uint8_t byte : digest) {
    output << std::setw(2) << static_cast<int>(byte);
  }
  return output.str();
}

bool ReadFile(const std::string& path, std::vector<uint8_t>* bytes) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) return false;
  const std::streampos end = input.tellg();
  if (end < 0) return false;
  const auto size = static_cast<uint64_t>(end);
  if (size > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    return false;
  }
  bytes->resize(static_cast<size_t>(size));
  input.seekg(0, std::ios::beg);
  if (!bytes->empty()) {
    input.read(reinterpret_cast<char*>(bytes->data()),
               static_cast<std::streamsize>(bytes->size()));
  }
  return input.good() || input.eof();
}

bool AtomicWrite(const std::string& path, const std::vector<uint8_t>& bytes) {
  const std::string temporary = path + ".tmp";
  std::remove(temporary.c_str());
  std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
  if (!output) return false;
  if (!bytes.empty()) {
    output.write(reinterpret_cast<const char*>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()));
  }
  output.close();
  if (!output) {
    std::remove(temporary.c_str());
    return false;
  }
  if (std::rename(temporary.c_str(), path.c_str()) != 0) {
    std::remove(temporary.c_str());
    return false;
  }
  return true;
}

void AppendU32(uint32_t value, std::vector<uint8_t>* output) {
  for (int shift = 0; shift < 32; shift += 8) {
    output->push_back(static_cast<uint8_t>((value >> shift) & 0xffu));
  }
}

void AppendU64(uint64_t value, std::vector<uint8_t>* output) {
  for (int shift = 0; shift < 64; shift += 8) {
    output->push_back(static_cast<uint8_t>((value >> shift) & 0xffu));
  }
}

void AppendComponentRegion(const brunsli::JPEGComponent& component,
                           size_t top, size_t left, size_t height,
                           size_t width, std::vector<uint8_t>* payload) {
  AppendU32(static_cast<uint32_t>(component.id), payload);
  AppendU32(static_cast<uint32_t>(component.h_samp_factor), payload);
  AppendU32(static_cast<uint32_t>(component.v_samp_factor), payload);
  AppendU32(static_cast<uint32_t>(component.quant_idx), payload);
  AppendU32(static_cast<uint32_t>(width), payload);
  AppendU32(static_cast<uint32_t>(height), payload);
  AppendU64(width * height * 64, payload);
  for (size_t row = top; row < top + height; ++row) {
    for (size_t column = left; column < left + width; ++column) {
      const size_t block_offset =
          (row * component.width_in_blocks + column) * 64;
      for (size_t coefficient_index = 0; coefficient_index < 64;
           ++coefficient_index) {
        const uint16_t bits = static_cast<uint16_t>(
            component.coeffs[block_offset + coefficient_index]);
        payload->push_back(static_cast<uint8_t>(bits & 0xffu));
        payload->push_back(static_cast<uint8_t>((bits >> 8) & 0xffu));
      }
    }
  }
}

std::vector<uint8_t> BuildEnvelope(const std::vector<uint8_t>& source,
                                   const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> envelope;
  envelope.reserve(8 + 8 + kDigestBytes + 8 + kDigestBytes + payload.size());
  envelope.insert(envelope.end(), kMagic.begin(), kMagic.end());
  AppendU64(payload.size(), &envelope);
  const auto payload_sha = Sha256(payload);
  envelope.insert(envelope.end(), payload_sha.begin(), payload_sha.end());
  AppendU64(source.size(), &envelope);
  const auto source_sha = Sha256(source);
  envelope.insert(envelope.end(), source_sha.begin(), source_sha.end());
  envelope.insert(envelope.end(), payload.begin(), payload.end());
  return envelope;
}

bool PublishEnvelope(const std::vector<uint8_t>& source,
                     const std::vector<uint8_t>& payload,
                     const std::string& output_path) {
  const std::vector<uint8_t> envelope = BuildEnvelope(source, payload);
  if (!AtomicWrite(output_path, envelope)) {
    std::cerr << "failed to publish training coefficient tensor\n";
    return false;
  }
  return true;
}

bool Extract(const std::string& source_path, const std::string& output_path) {
  std::vector<uint8_t> source;
  if (!ReadFile(source_path, &source)) {
    std::cerr << "failed to read source JPEG\n";
    return false;
  }
  brunsli::JPEGData jpeg;
  if (!brunsli::ReadJpeg(source.data(), source.size(), brunsli::JPEG_READ_ALL,
                         &jpeg)) {
    std::cerr << "Brunsli ReadJpeg rejected source\n";
    return false;
  }
  if (jpeg.components.size() != 3) {
    std::cerr << "Phase 2 requires exactly three JPEG components\n";
    return false;
  }

  std::vector<uint8_t> payload;
  AppendU32(static_cast<uint32_t>(jpeg.width), &payload);
  AppendU32(static_cast<uint32_t>(jpeg.height), &payload);
  AppendU32(static_cast<uint32_t>(jpeg.max_h_samp_factor), &payload);
  AppendU32(static_cast<uint32_t>(jpeg.max_v_samp_factor), &payload);
  AppendU32(static_cast<uint32_t>(jpeg.components.size()), &payload);
  for (const auto& component : jpeg.components) {
    AppendU32(static_cast<uint32_t>(component.id), &payload);
    AppendU32(static_cast<uint32_t>(component.h_samp_factor), &payload);
    AppendU32(static_cast<uint32_t>(component.v_samp_factor), &payload);
    AppendU32(static_cast<uint32_t>(component.quant_idx), &payload);
    AppendU32(static_cast<uint32_t>(component.width_in_blocks), &payload);
    AppendU32(static_cast<uint32_t>(component.height_in_blocks), &payload);
    AppendU64(component.coeffs.size(), &payload);
    for (brunsli::coeff_t coefficient : component.coeffs) {
      const uint16_t bits = static_cast<uint16_t>(coefficient);
      payload.push_back(static_cast<uint8_t>(bits & 0xffu));
      payload.push_back(static_cast<uint8_t>((bits >> 8) & 0xffu));
    }
  }

  if (!PublishEnvelope(source, payload, output_path)) return false;
  std::cout << "width=" << jpeg.width << " height=" << jpeg.height
            << " components=" << jpeg.components.size()
            << " payload_bytes=" << payload.size() << "\n";
  return true;
}

bool ExtractPatch(const std::string& source_path, const std::string& output_path,
                  uint32_t luma_top, uint32_t luma_left,
                  uint32_t luma_blocks) {
  std::vector<uint8_t> source;
  if (!ReadFile(source_path, &source)) {
    std::cerr << "failed to read source JPEG\n";
    return false;
  }
  brunsli::JPEGData jpeg;
  if (!brunsli::ReadJpeg(source.data(), source.size(), brunsli::JPEG_READ_ALL,
                         &jpeg)) {
    std::cerr << "Brunsli ReadJpeg rejected source\n";
    return false;
  }
  if (jpeg.components.size() != 3 || jpeg.max_h_samp_factor != 2 ||
      jpeg.max_v_samp_factor != 2 ||
      jpeg.components[0].h_samp_factor != 2 ||
      jpeg.components[0].v_samp_factor != 2 ||
      jpeg.components[1].h_samp_factor != 1 ||
      jpeg.components[1].v_samp_factor != 1 ||
      jpeg.components[2].h_samp_factor != 1 ||
      jpeg.components[2].v_samp_factor != 1) {
    std::cerr << "patch extraction requires exact three-component 4:2:0\n";
    return false;
  }
  const auto& y = jpeg.components[0];
  const auto& cb = jpeg.components[1];
  const auto& cr = jpeg.components[2];
  if (luma_blocks == 0 || luma_blocks % 2 != 0 || luma_top % 2 != 0 ||
      luma_left % 2 != 0 ||
      static_cast<uint64_t>(luma_top) + luma_blocks >
          static_cast<uint64_t>(y.height_in_blocks) ||
      static_cast<uint64_t>(luma_left) + luma_blocks >
          static_cast<uint64_t>(y.width_in_blocks) ||
      y.width_in_blocks != cb.width_in_blocks * 2 ||
      y.height_in_blocks != cb.height_in_blocks * 2 ||
      cb.width_in_blocks != cr.width_in_blocks ||
      cb.height_in_blocks != cr.height_in_blocks) {
    std::cerr << "invalid luma patch origin, extent, or component geometry\n";
    return false;
  }

  std::vector<uint8_t> payload;
  AppendU32(luma_blocks * 8, &payload);
  AppendU32(luma_blocks * 8, &payload);
  AppendU32(2, &payload);
  AppendU32(2, &payload);
  AppendU32(3, &payload);
  AppendComponentRegion(y, luma_top, luma_left, luma_blocks, luma_blocks,
                        &payload);
  const uint32_t chroma_blocks = luma_blocks / 2;
  AppendComponentRegion(cb, luma_top / 2, luma_left / 2, chroma_blocks,
                        chroma_blocks, &payload);
  AppendComponentRegion(cr, luma_top / 2, luma_left / 2, chroma_blocks,
                        chroma_blocks, &payload);
  if (output_path == "-") {
    const std::vector<uint8_t> envelope = BuildEnvelope(source, payload);
    std::cout.write(reinterpret_cast<const char*>(envelope.data()),
                    static_cast<std::streamsize>(envelope.size()));
    if (!std::cout) return false;
  } else {
    if (!PublishEnvelope(source, payload, output_path)) return false;
    std::cout << "luma_top=" << luma_top << " luma_left=" << luma_left
              << " luma_blocks=" << luma_blocks
              << " payload_bytes=" << payload.size() << "\n";
  }
  return true;
}

bool ParseU32(const char* text, uint32_t* value) {
  char* end = nullptr;
  const unsigned long long parsed = std::strtoull(text, &end, 10);
  if (text[0] == '\0' || end == nullptr || *end != '\0' ||
      parsed > std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  *value = static_cast<uint32_t>(parsed);
  return true;
}

bool Probe(const std::string& source_path) {
  std::vector<uint8_t> source;
  if (!ReadFile(source_path, &source)) {
    std::cerr << "failed to read source JPEG\n";
    return false;
  }
  brunsli::JPEGData jpeg;
  if (!brunsli::ReadJpeg(source.data(), source.size(), brunsli::JPEG_READ_ALL,
                         &jpeg)) {
    std::cerr << "Brunsli ReadJpeg rejected source\n";
    return false;
  }
  const bool three_components = jpeg.components.size() == 3;
  const bool is_420 =
      three_components && jpeg.max_h_samp_factor == 2 &&
      jpeg.max_v_samp_factor == 2 &&
      jpeg.components[0].h_samp_factor == 2 &&
      jpeg.components[0].v_samp_factor == 2 &&
      jpeg.components[1].h_samp_factor == 1 &&
      jpeg.components[1].v_samp_factor == 1 &&
      jpeg.components[2].h_samp_factor == 1 &&
      jpeg.components[2].v_samp_factor == 1;
  bool exact_geometry = false;
  if (is_420) {
    const auto& y = jpeg.components[0];
    const auto& cb = jpeg.components[1];
    const auto& cr = jpeg.components[2];
    exact_geometry =
        y.width_in_blocks == cb.width_in_blocks * 2 &&
        y.height_in_blocks == cb.height_in_blocks * 2 &&
        cb.width_in_blocks == cr.width_in_blocks &&
        cb.height_in_blocks == cr.height_in_blocks &&
        y.width_in_blocks >= 32 && y.height_in_blocks >= 32;
  }
  std::string subsampling = "other";
  if (is_420) subsampling = "4:2:0";
  std::cout << "{\"width\":" << jpeg.width << ",\"height\":" << jpeg.height
            << ",\"component_count\":" << jpeg.components.size()
            << ",\"luma_width_in_blocks\":"
            << (three_components ? jpeg.components[0].width_in_blocks : 0)
            << ",\"luma_height_in_blocks\":"
            << (three_components ? jpeg.components[0].height_in_blocks : 0)
            << ",\"subsampling\":\"" << subsampling
            << "\",\"eligible_plr_420\":"
            << (exact_geometry ? "true" : "false")
            << ",\"source_bytes\":" << source.size()
            << ",\"source_sha256\":\"" << HexDigest(Sha256(source))
            << "\"}\n";
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 3 && std::string(argv[1]) == "--probe") {
    return Probe(argv[2]) ? 0 : 3;
  }
  if (argc == 7 && std::string(argv[1]) == "--extract-patch") {
    uint32_t luma_top = 0;
    uint32_t luma_left = 0;
    uint32_t luma_blocks = 0;
    if (!ParseU32(argv[4], &luma_top) || !ParseU32(argv[5], &luma_left) ||
        !ParseU32(argv[6], &luma_blocks)) {
      std::cerr << "invalid unsigned patch coordinate\n";
      return 2;
    }
    return ExtractPatch(argv[2], argv[3], luma_top, luma_left, luma_blocks)
               ? 0
               : 3;
  }
  if (argc != 3) {
    std::cerr << "usage: pw_brunsli_training_extract SOURCE.jpg OUTPUT.pwtj\n"
              << "       pw_brunsli_training_extract --probe SOURCE.jpg\n"
              << "       pw_brunsli_training_extract --extract-patch "
                 "SOURCE.jpg OUTPUT.pwtj LUMA_TOP LUMA_LEFT LUMA_BLOCKS\n";
    return 2;
  }
  return Extract(argv[1], argv[2]) ? 0 : 3;
}
