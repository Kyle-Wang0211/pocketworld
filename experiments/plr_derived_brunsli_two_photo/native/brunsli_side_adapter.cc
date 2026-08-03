#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include <brunsli/brunsli_encode.h>
#include <brunsli/jpeg_data.h>
#include <brunsli/jpeg_data_reader.h>
#include <brunsli/jpeg_data_writer.h>
#include <brunsli/status.h>

#include "c/common/constants.h"
#include "c/dec/state.h"
#include "c/enc/state.h"

namespace {

constexpr std::array<uint8_t, 8> kSideMagic = {'P', 'W', 'B', 'S', '1', 0, 0, 0};
constexpr std::array<uint8_t, 8> kCoefficientMagic = {
    'P', 'W', 'C', 'F', '1', 0, 0, 0};
constexpr size_t kDigestBytes = CC_SHA256_DIGEST_LENGTH;
constexpr size_t kEnvelopeHeaderBytes = 8 + 8 + 8 + kDigestBytes + kDigestBytes;

struct Envelope {
  uint64_t source_bytes = 0;
  std::array<uint8_t, kDigestBytes> source_sha{};
  std::vector<uint8_t> payload;
};

std::array<uint8_t, kDigestBytes> Sha256(const std::vector<uint8_t>& bytes) {
  std::array<uint8_t, kDigestBytes> digest{};
  const void* data = bytes.empty() ? static_cast<const void*>("") : bytes.data();
  CC_SHA256(data, static_cast<CC_LONG>(bytes.size()), digest.data());
  return digest;
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

bool ReadU32(const std::vector<uint8_t>& input, size_t* position,
             uint32_t* value) {
  if (*position > input.size() || input.size() - *position < 4) return false;
  uint32_t decoded = 0;
  for (int shift = 0; shift < 32; shift += 8) {
    decoded |= static_cast<uint32_t>(input[(*position)++]) << shift;
  }
  *value = decoded;
  return true;
}

bool ReadU64(const std::vector<uint8_t>& input, size_t* position,
             uint64_t* value) {
  if (*position > input.size() || input.size() - *position < 8) return false;
  uint64_t decoded = 0;
  for (int shift = 0; shift < 64; shift += 8) {
    decoded |= static_cast<uint64_t>(input[(*position)++]) << shift;
  }
  *value = decoded;
  return true;
}

std::vector<uint8_t> BuildEnvelope(
    const std::array<uint8_t, 8>& magic,
    const std::vector<uint8_t>& payload,
    const std::vector<uint8_t>& source) {
  std::vector<uint8_t> envelope;
  envelope.reserve(kEnvelopeHeaderBytes + payload.size());
  envelope.insert(envelope.end(), magic.begin(), magic.end());
  AppendU64(payload.size(), &envelope);
  AppendU64(source.size(), &envelope);
  const auto payload_sha = Sha256(payload);
  const auto source_sha = Sha256(source);
  envelope.insert(envelope.end(), payload_sha.begin(), payload_sha.end());
  envelope.insert(envelope.end(), source_sha.begin(), source_sha.end());
  envelope.insert(envelope.end(), payload.begin(), payload.end());
  return envelope;
}

bool ParseEnvelope(const std::vector<uint8_t>& bytes,
                   const std::array<uint8_t, 8>& expected_magic,
                   Envelope* envelope) {
  if (bytes.size() < kEnvelopeHeaderBytes) return false;
  if (!std::equal(expected_magic.begin(), expected_magic.end(), bytes.begin())) {
    return false;
  }
  size_t position = expected_magic.size();
  uint64_t payload_bytes = 0;
  if (!ReadU64(bytes, &position, &payload_bytes) ||
      !ReadU64(bytes, &position, &envelope->source_bytes)) {
    return false;
  }
  std::array<uint8_t, kDigestBytes> expected_payload_sha{};
  std::copy_n(bytes.begin() + static_cast<std::ptrdiff_t>(position),
              kDigestBytes, expected_payload_sha.begin());
  position += kDigestBytes;
  std::copy_n(bytes.begin() + static_cast<std::ptrdiff_t>(position),
              kDigestBytes, envelope->source_sha.begin());
  position += kDigestBytes;
  if (payload_bytes != bytes.size() - position) return false;
  envelope->payload.assign(bytes.begin() + static_cast<std::ptrdiff_t>(position),
                           bytes.end());
  return Sha256(envelope->payload) == expected_payload_sha;
}

std::vector<uint8_t> EncodeCoefficients(const brunsli::JPEGData& jpeg) {
  std::vector<uint8_t> output;
  AppendU32(static_cast<uint32_t>(jpeg.components.size()), &output);
  for (const auto& component : jpeg.components) {
    AppendU64(component.coeffs.size(), &output);
    for (brunsli::coeff_t coefficient : component.coeffs) {
      const uint16_t bits = static_cast<uint16_t>(coefficient);
      output.push_back(static_cast<uint8_t>(bits & 0xffu));
      output.push_back(static_cast<uint8_t>((bits >> 8) & 0xffu));
    }
  }
  return output;
}

bool DecodeCoefficients(const std::vector<uint8_t>& payload,
                        brunsli::JPEGData* jpeg) {
  size_t position = 0;
  uint32_t component_count = 0;
  if (!ReadU32(payload, &position, &component_count) ||
      component_count != jpeg->components.size()) {
    return false;
  }
  for (auto& component : jpeg->components) {
    uint64_t coefficient_count = 0;
    if (!ReadU64(payload, &position, &coefficient_count) ||
        coefficient_count != component.coeffs.size()) {
      return false;
    }
    if (coefficient_count > (payload.size() - position) / 2) return false;
    for (size_t i = 0; i < component.coeffs.size(); ++i) {
      const uint16_t low = payload[position++];
      const uint16_t high = payload[position++];
      component.coeffs[i] = static_cast<int16_t>(low | (high << 8));
    }
  }
  return position == payload.size();
}

int AppendJpegOutput(void* opaque, const uint8_t* data, size_t size) {
  if (size > static_cast<size_t>(std::numeric_limits<int>::max())) return -1;
  auto* output = static_cast<std::vector<uint8_t>*>(opaque);
  output->insert(output->end(), data, data + size);
  return static_cast<int>(size);
}

bool Extract(const std::string& source_path, const std::string& side_path,
             const std::string& coefficient_path) {
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

  brunsli::internal::enc::State state;
  if (!brunsli::internal::enc::CalculateMeta(jpeg, &state)) {
    std::cerr << "Brunsli CalculateMeta failed\n";
    return false;
  }

  std::vector<uint8_t> side(brunsli::GetMaximumBrunsliEncodedSize(jpeg));
  size_t side_size = side.size();
  const uint32_t skip_sections =
      (1u << brunsli::kBrunsliHistogramDataTag) |
      (1u << brunsli::kBrunsliDCDataTag) |
      (1u << brunsli::kBrunsliACDataTag);
  if (!brunsli::internal::enc::BrunsliSerialize(
          &state, jpeg, skip_sections, side.data(), &side_size)) {
    std::cerr << "Brunsli side serialization failed\n";
    return false;
  }
  side.resize(side_size);
  const std::vector<uint8_t> coefficients = EncodeCoefficients(jpeg);
  const std::vector<uint8_t> side_envelope =
      BuildEnvelope(kSideMagic, side, source);
  const std::vector<uint8_t> coefficient_envelope =
      BuildEnvelope(kCoefficientMagic, coefficients, source);

  if (!AtomicWrite(side_path, side_envelope) ||
      !AtomicWrite(coefficient_path, coefficient_envelope)) {
    std::cerr << "failed to publish extracted payloads\n";
    return false;
  }
  std::cout << "side_bytes=" << side_envelope.size()
            << " coefficient_bytes=" << coefficient_envelope.size() << "\n";
  return true;
}

bool Restore(const std::string& side_path, const std::string& coefficient_path,
             const std::string& output_path) {
  std::remove(output_path.c_str());
  std::remove((output_path + ".tmp").c_str());

  std::vector<uint8_t> side_file;
  std::vector<uint8_t> coefficient_file;
  if (!ReadFile(side_path, &side_file) ||
      !ReadFile(coefficient_path, &coefficient_file)) {
    std::cerr << "failed to read restore payloads\n";
    return false;
  }
  Envelope side;
  Envelope coefficients;
  if (!ParseEnvelope(side_file, kSideMagic, &side) ||
      !ParseEnvelope(coefficient_file, kCoefficientMagic, &coefficients)) {
    std::cerr << "payload envelope verification failed\n";
    return false;
  }
  if (side.source_bytes != coefficients.source_bytes ||
      side.source_sha != coefficients.source_sha) {
    std::cerr << "side and coefficient source identities differ\n";
    return false;
  }

  brunsli::JPEGData jpeg;
  brunsli::internal::dec::State state;
  state.data = side.payload.data();
  state.len = side.payload.size();
  const brunsli::BrunsliStatus status =
      brunsli::internal::dec::ProcessJpeg(&state, &jpeg);
  if (status != brunsli::BRUNSLI_NOT_ENOUGH_DATA ||
      state.pos != state.len) {
    std::cerr << "Brunsli side parse did not stop at the expected boundary\n";
    return false;
  }
  brunsli::internal::dec::PrepareMeta(&jpeg, &state);
  brunsli::internal::dec::WarmupMeta(&jpeg, &state);
  if (!DecodeCoefficients(coefficients.payload, &jpeg)) {
    std::cerr << "coefficient payload shape or length mismatch\n";
    return false;
  }

  std::vector<uint8_t> restored;
  const brunsli::JPEGOutput writer(AppendJpegOutput, &restored);
  if (!brunsli::WriteJpeg(jpeg, writer)) {
    std::cerr << "Brunsli WriteJpeg failed\n";
    return false;
  }
  if (restored.size() != side.source_bytes ||
      Sha256(restored) != side.source_sha) {
    std::cerr << "restored source identity mismatch\n";
    return false;
  }
  if (!AtomicWrite(output_path, restored)) {
    std::cerr << "failed to publish restored JPEG\n";
    return false;
  }
  std::cout << "restored_bytes=" << restored.size() << "\n";
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 5) {
    std::cerr << "usage: pw_brunsli_side_adapter "
                 "extract SOURCE.jpg SIDE.pwbs COEFF.pwcf\n"
                 "   or: pw_brunsli_side_adapter "
                 "restore SIDE.pwbs COEFF.pwcf OUTPUT.jpg\n";
    return 2;
  }
  const std::string command = argv[1];
  if (command == "extract") {
    return Extract(argv[2], argv[3], argv[4]) ? 0 : 3;
  }
  if (command == "restore") {
    return Restore(argv[2], argv[3], argv[4]) ? 0 : 4;
  }
  std::cerr << "unknown command\n";
  return 2;
}
