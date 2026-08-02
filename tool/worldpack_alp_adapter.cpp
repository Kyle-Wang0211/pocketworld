#include "worldpack_alp_adapter.h"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "alp/encoder.hpp"
#include "alp/rd.hpp"
#include "fastlanes/ffor.hpp"
#include "fastlanes/unffor.hpp"

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "The frozen WorldPack ALP framing currently requires little endian."
#endif

namespace {

using ElementType = pw::worldpack::alp_codec::ElementType;
using Result = pw::worldpack::alp_codec::Result;

constexpr char kRevision[] =
    "31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce";
constexpr std::array<std::uint8_t, 8> kMagic = {'P', 'W', 'A', 'L', 'P', '1', 0, 0};
constexpr std::uint32_t kVersion = 1;
constexpr std::size_t kVectorSize = alp::config::VECTOR_SIZE;
constexpr std::size_t kRowGroupSize = alp::config::ROWGROUP_SIZE;
constexpr std::size_t kHeaderSize = 100;

class Failure final : public std::runtime_error {
 public:
  explicit Failure(const std::string& message) : std::runtime_error(message) {}
};

class Writer final {
 public:
  void U8(const std::uint8_t value) { bytes_.push_back(value); }

  void U16(const std::uint16_t value) {
    U8(static_cast<std::uint8_t>(value));
    U8(static_cast<std::uint8_t>(value >> 8));
  }

  void U32(const std::uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) {
      U8(static_cast<std::uint8_t>(value >> shift));
    }
  }

  void U64(const std::uint64_t value) {
    for (int shift = 0; shift < 64; shift += 8) {
      U8(static_cast<std::uint8_t>(value >> shift));
    }
  }

  void Bytes(const void* data, const std::size_t size) {
    const auto* begin = static_cast<const std::uint8_t*>(data);
    bytes_.insert(bytes_.end(), begin, begin + size);
  }

  const std::vector<std::uint8_t>& bytes() const { return bytes_; }
  std::vector<std::uint8_t> Take() { return std::move(bytes_); }

 private:
  std::vector<std::uint8_t> bytes_;
};

class Reader final {
 public:
  explicit Reader(const std::vector<std::uint8_t>& bytes)
      : bytes_(bytes) {}

  std::uint8_t U8() {
    Require(1);
    return bytes_[position_++];
  }

  std::uint16_t U16() {
    std::uint16_t value = 0;
    for (int shift = 0; shift < 16; shift += 8) {
      value |= static_cast<std::uint16_t>(U8()) << shift;
    }
    return value;
  }

  std::uint32_t U32() {
    std::uint32_t value = 0;
    for (int shift = 0; shift < 32; shift += 8) {
      value |= static_cast<std::uint32_t>(U8()) << shift;
    }
    return value;
  }

  std::uint64_t U64() {
    std::uint64_t value = 0;
    for (int shift = 0; shift < 64; shift += 8) {
      value |= static_cast<std::uint64_t>(U8()) << shift;
    }
    return value;
  }

  void Bytes(void* destination, const std::size_t size) {
    Require(size);
    std::memcpy(destination, bytes_.data() + position_, size);
    position_ += size;
  }

  std::vector<std::uint8_t> ByteVector(const std::size_t size) {
    Require(size);
    std::vector<std::uint8_t> result(
        bytes_.begin() + static_cast<std::ptrdiff_t>(position_),
        bytes_.begin() + static_cast<std::ptrdiff_t>(position_ + size));
    position_ += size;
    return result;
  }

  bool done() const { return position_ == bytes_.size(); }

 private:
  void Require(const std::size_t size) const {
    if (size > bytes_.size() - position_) {
      throw Failure("ALP archive is truncated");
    }
  }

  const std::vector<std::uint8_t>& bytes_;
  std::size_t position_ = 0;
};

std::vector<std::uint8_t> ReadFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw Failure("could not open input: " + path.string());
  }
  return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(input),
                                   std::istreambuf_iterator<char>());
}

void WriteNewFile(const std::filesystem::path& path,
                  const std::vector<std::uint8_t>& bytes) {
  std::error_code exists_error;
  if (std::filesystem::exists(path, exists_error) || exists_error) {
    throw Failure("output path already exists: " + path.string());
  }
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output) {
    throw Failure("could not open output: " + path.string());
  }
  output.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  output.flush();
  if (!output.good()) {
    output.close();
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
    throw Failure("could not write output: " + path.string());
  }
}

std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> Sha256(
    const std::vector<std::uint8_t>& bytes) {
  if (bytes.size() > std::numeric_limits<CC_LONG>::max()) {
    throw Failure("SHA-256 input is too large for the frozen adapter");
  }
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> digest{};
  const void* data = bytes.empty() ? static_cast<const void*>("") : bytes.data();
  if (CC_SHA256(data, static_cast<CC_LONG>(bytes.size()), digest.data()) ==
      nullptr) {
    throw Failure("SHA-256 failed");
  }
  return digest;
}

template <class PT>
void AppendRaw(Writer* writer, const PT& value) {
  writer->Bytes(&value, sizeof(value));
}

template <class PT>
void CompressColumn(const std::vector<std::uint8_t>& input,
                    Writer* body,
                    Result* result) {
  using ST = typename alp::inner_t<PT>::st;
  using UT = typename alp::inner_t<PT>::ut;
  if (input.empty() || input.size() % sizeof(PT) != 0) {
    throw Failure("ALP input is empty or not aligned to its element width");
  }
  const std::size_t total_count = input.size() / sizeof(PT);
  std::vector<PT> values(total_count);
  std::memcpy(values.data(), input.data(), input.size());
  const std::size_t row_group_count =
      (total_count + kRowGroupSize - 1) / kRowGroupSize;
  if (row_group_count > std::numeric_limits<std::uint32_t>::max()) {
    throw Failure("ALP row-group count is too large");
  }
  body->U32(static_cast<std::uint32_t>(row_group_count));

  std::size_t source_offset = 0;
  for (std::size_t row_group = 0; row_group < row_group_count; ++row_group) {
    const std::size_t valid_count =
        std::min(kRowGroupSize, total_count - source_offset);
    const std::size_t vector_count =
        (valid_count + kVectorSize - 1) / kVectorSize;
    std::vector<PT> padded(vector_count * kVectorSize, static_cast<PT>(0));
    std::copy_n(values.begin() + static_cast<std::ptrdiff_t>(source_offset),
                valid_count, padded.begin());
    result->padded_values += padded.size() - valid_count;

    alignas(64) std::array<PT, kVectorSize> sample{};
    alp::state<PT> state;
    alp::encoder<PT>::init(padded.data(), 0, valid_count, sample.data(), state);
    if (state.scheme == alp::Scheme::ALP_RD) {
      alp::rd_encoder<PT>::init(padded.data(), 0, valid_count, sample.data(),
                                state);
    }
    if (state.scheme != alp::Scheme::ALP &&
        state.scheme != alp::Scheme::ALP_RD) {
      throw Failure("official ALP selected an invalid scheme");
    }

    body->U32(static_cast<std::uint32_t>(valid_count));
    body->U16(static_cast<std::uint16_t>(vector_count));
    body->U8(static_cast<std::uint8_t>(state.scheme));
    body->U8(0);
    if (state.scheme == alp::Scheme::ALP_RD) {
      body->U8(state.actual_dictionary_size);
      body->U8(state.right_bit_width);
      body->U8(state.left_bit_width);
      body->U8(0);
      for (std::size_t index = 0; index < state.actual_dictionary_size;
           ++index) {
        body->U16(state.left_parts_dict[index]);
      }
    }

    for (std::size_t vector_index = 0; vector_index < vector_count;
         ++vector_index) {
      const std::size_t vector_offset = vector_index * kVectorSize;
      const std::size_t vector_valid =
          std::min(kVectorSize, valid_count - vector_offset);
      state.vector_size = static_cast<std::uint16_t>(vector_valid);
      body->U16(static_cast<std::uint16_t>(vector_valid));
      body->U8(static_cast<std::uint8_t>(state.scheme));
      body->U8(0);

      if (state.scheme == alp::Scheme::ALP) {
        alignas(64) std::array<PT, kVectorSize> exceptions{};
        alignas(64) std::array<std::uint16_t, kVectorSize> positions{};
        alignas(64) std::array<ST, kVectorSize> encoded{};
        alignas(64) std::array<ST, kVectorSize> packed{};
        ST base = 0;
        std::uint16_t exception_count = 0;
        alp::encoder<PT>::encode(padded.data() + vector_offset,
                                 exceptions.data(), positions.data(),
                                 &exception_count, encoded.data(), state);
        alp::encoder<PT>::analyze_ffor(encoded.data(), state.bit_width, &base);
        ffor::ffor(encoded.data(), packed.data(), state.bit_width, &base);
        const std::size_t packed_bytes =
            kVectorSize * static_cast<std::size_t>(state.bit_width) / 8;
        body->U8(state.fac);
        body->U8(state.exp);
        body->U8(state.bit_width);
        body->U8(0);
        AppendRaw(body, base);
        body->U16(exception_count);
        body->U16(0);
        body->U32(static_cast<std::uint32_t>(packed_bytes));
        for (std::size_t index = 0; index < exception_count; ++index) {
          body->U16(positions[index]);
          AppendRaw(body, exceptions[index]);
        }
        body->Bytes(packed.data(), packed_bytes);
        ++result->alp_vectors;
      } else {
        alignas(64) std::array<std::uint16_t, kVectorSize> exceptions{};
        alignas(64) std::array<std::uint16_t, kVectorSize> positions{};
        alignas(64) std::array<UT, kVectorSize> right{};
        alignas(64) std::array<std::uint16_t, kVectorSize> left{};
        alignas(64) std::array<UT, kVectorSize> packed_right{};
        alignas(64) std::array<std::uint16_t, kVectorSize> packed_left{};
        std::uint16_t exception_count = 0;
        alp::rd_encoder<PT>::encode(
            padded.data() + vector_offset, exceptions.data(), positions.data(),
            &exception_count, right.data(), left.data(), state);
        ffor::ffor(right.data(), packed_right.data(), state.right_bit_width,
                   &state.right_for_base);
        ffor::ffor(left.data(), packed_left.data(), state.left_bit_width,
                   &state.left_for_base);
        const std::size_t right_bytes =
            kVectorSize * static_cast<std::size_t>(state.right_bit_width) / 8;
        const std::size_t left_bytes =
            kVectorSize * static_cast<std::size_t>(state.left_bit_width) / 8;
        body->U8(state.right_bit_width);
        body->U8(state.left_bit_width);
        body->U8(state.actual_dictionary_size);
        body->U8(0);
        body->U16(exception_count);
        body->U16(0);
        body->U32(static_cast<std::uint32_t>(right_bytes));
        body->U32(static_cast<std::uint32_t>(left_bytes));
        for (std::size_t index = 0; index < exception_count; ++index) {
          body->U16(positions[index]);
          body->U16(exceptions[index]);
        }
        body->Bytes(packed_right.data(), right_bytes);
        body->Bytes(packed_left.data(), left_bytes);
        ++result->alprd_vectors;
      }
    }
    source_offset += valid_count;
  }
}

template <class PT>
std::vector<std::uint8_t> DecompressColumn(Reader* body,
                                           const std::uint64_t total_count,
                                           Result* result) {
  using ST = typename alp::inner_t<PT>::st;
  using UT = typename alp::inner_t<PT>::ut;
  if (total_count == 0 || total_count >
                              std::numeric_limits<std::size_t>::max() /
                                  sizeof(PT)) {
    throw Failure("ALP element count is invalid");
  }
  const std::uint32_t row_group_count = body->U32();
  const std::uint64_t expected_row_groups =
      (total_count + kRowGroupSize - 1) / kRowGroupSize;
  if (row_group_count != expected_row_groups) {
    throw Failure("ALP row-group count is inconsistent");
  }
  std::vector<std::uint8_t> output;
  output.reserve(static_cast<std::size_t>(total_count) * sizeof(PT));
  std::uint64_t restored_count = 0;

  for (std::uint32_t row_group = 0; row_group < row_group_count;
       ++row_group) {
    const std::uint32_t valid_count = body->U32();
    const std::uint16_t vector_count = body->U16();
    const auto scheme = static_cast<alp::Scheme>(body->U8());
    if (body->U8() != 0 || valid_count == 0 || valid_count > kRowGroupSize ||
        vector_count != (valid_count + kVectorSize - 1) / kVectorSize ||
        (scheme != alp::Scheme::ALP && scheme != alp::Scheme::ALP_RD)) {
      throw Failure("ALP row-group header is invalid");
    }
    alp::state<PT> state;
    state.scheme = scheme;
    if (scheme == alp::Scheme::ALP_RD) {
      state.actual_dictionary_size = body->U8();
      state.right_bit_width = body->U8();
      state.left_bit_width = body->U8();
      if (body->U8() != 0 || state.actual_dictionary_size == 0 ||
          state.actual_dictionary_size > alp::config::MAX_RD_DICTIONARY_SIZE) {
        throw Failure("ALP-RD dictionary header is invalid");
      }
      for (std::size_t index = 0; index < state.actual_dictionary_size;
           ++index) {
        state.left_parts_dict[index] = body->U16();
      }
    }

    std::uint32_t row_restored = 0;
    for (std::uint16_t vector_index = 0; vector_index < vector_count;
         ++vector_index) {
      const std::uint16_t vector_valid = body->U16();
      const auto vector_scheme = static_cast<alp::Scheme>(body->U8());
      if (body->U8() != 0 || vector_scheme != scheme || vector_valid == 0 ||
          vector_valid > kVectorSize ||
          vector_valid != std::min<std::uint32_t>(
                              kVectorSize, valid_count - row_restored)) {
        throw Failure("ALP vector header is invalid");
      }
      alignas(64) std::array<PT, kVectorSize> decoded{};
      if (scheme == alp::Scheme::ALP) {
        state.fac = body->U8();
        state.exp = body->U8();
        state.bit_width = body->U8();
        if (body->U8() != 0 || state.bit_width > sizeof(ST) * 8) {
          throw Failure("ALP vector parameters are invalid");
        }
        ST base = 0;
        body->Bytes(&base, sizeof(base));
        std::uint16_t exception_count = body->U16();
        if (body->U16() != 0 || exception_count > kVectorSize) {
          throw Failure("ALP exception count is invalid");
        }
        const std::uint32_t packed_bytes = body->U32();
        const std::size_t expected_packed =
            kVectorSize * static_cast<std::size_t>(state.bit_width) / 8;
        if (packed_bytes != expected_packed) {
          throw Failure("ALP packed length is inconsistent");
        }
        alignas(64) std::array<PT, kVectorSize> exceptions{};
        alignas(64) std::array<std::uint16_t, kVectorSize> positions{};
        std::array<bool, kVectorSize> seen{};
        for (std::size_t index = 0; index < exception_count; ++index) {
          positions[index] = body->U16();
          if (positions[index] >= kVectorSize || seen[positions[index]]) {
            throw Failure("ALP exception position is invalid");
          }
          seen[positions[index]] = true;
          body->Bytes(&exceptions[index], sizeof(PT));
        }
        alignas(64) std::array<ST, kVectorSize> packed{};
        body->Bytes(packed.data(), packed_bytes);
        alignas(64) std::array<ST, kVectorSize> unpacked{};
        unffor::unffor(packed.data(), unpacked.data(), state.bit_width, &base);
        alp::decoder<PT>::decode(unpacked.data(), state.fac, state.exp,
                                 decoded.data());
        alp::decoder<PT>::patch_exceptions(
            decoded.data(), exceptions.data(), positions.data(),
            &exception_count);
        ++result->alp_vectors;
      } else {
        const std::uint8_t right_bit_width = body->U8();
        const std::uint8_t left_bit_width = body->U8();
        const std::uint8_t dictionary_size = body->U8();
        if (body->U8() != 0 || right_bit_width != state.right_bit_width ||
            left_bit_width != state.left_bit_width ||
            dictionary_size != state.actual_dictionary_size) {
          throw Failure("ALP-RD vector parameters are inconsistent");
        }
        std::uint16_t exception_count = body->U16();
        if (body->U16() != 0 || exception_count > kVectorSize) {
          throw Failure("ALP-RD exception count is invalid");
        }
        const std::uint32_t right_bytes = body->U32();
        const std::uint32_t left_bytes = body->U32();
        if (right_bytes != kVectorSize * right_bit_width / 8 ||
            left_bytes != kVectorSize * left_bit_width / 8) {
          throw Failure("ALP-RD packed length is inconsistent");
        }
        alignas(64) std::array<std::uint16_t, kVectorSize> exceptions{};
        alignas(64) std::array<std::uint16_t, kVectorSize> positions{};
        std::array<bool, kVectorSize> seen{};
        for (std::size_t index = 0; index < exception_count; ++index) {
          positions[index] = body->U16();
          exceptions[index] = body->U16();
          if (positions[index] >= kVectorSize || seen[positions[index]]) {
            throw Failure("ALP-RD exception position is invalid");
          }
          seen[positions[index]] = true;
        }
        alignas(64) std::array<UT, kVectorSize> packed_right{};
        alignas(64) std::array<std::uint16_t, kVectorSize> packed_left{};
        body->Bytes(packed_right.data(), right_bytes);
        body->Bytes(packed_left.data(), left_bytes);
        alignas(64) std::array<UT, kVectorSize> right{};
        alignas(64) std::array<std::uint16_t, kVectorSize> left{};
        state.right_for_base = 0;
        state.left_for_base = 0;
        unffor::unffor(packed_right.data(), right.data(), right_bit_width,
                       &state.right_for_base);
        unffor::unffor(packed_left.data(), left.data(), left_bit_width,
                       &state.left_for_base);
        for (std::size_t index = 0; index < kVectorSize; ++index) {
          if (left[index] >= state.actual_dictionary_size && !seen[index]) {
            throw Failure("ALP-RD dictionary index is invalid");
          }
        }
        for (std::size_t index = 0; index < exception_count; ++index) {
          left[positions[index]] = 0;
        }
        alp::rd_encoder<PT>::decode(decoded.data(), right.data(), left.data(),
                                    exceptions.data(), positions.data(),
                                    &exception_count, state);
        ++result->alprd_vectors;
      }
      const auto* decoded_bytes =
          reinterpret_cast<const std::uint8_t*>(decoded.data());
      output.insert(output.end(), decoded_bytes,
                    decoded_bytes + vector_valid * sizeof(PT));
      row_restored += vector_valid;
    }
    if (row_restored != valid_count) {
      throw Failure("ALP row-group restoration count is inconsistent");
    }
    restored_count += valid_count;
  }
  if (restored_count != total_count) {
    throw Failure("ALP total restoration count is inconsistent");
  }
  return output;
}

std::vector<std::uint8_t> BuildArchive(const ElementType type,
                                       const std::vector<std::uint8_t>& input,
                                       Result* result) {
  Writer body;
  if (type == ElementType::kFloat32) {
    CompressColumn<float>(input, &body, result);
  } else if (type == ElementType::kFloat64) {
    CompressColumn<double>(input, &body, result);
  } else {
    throw Failure("unsupported ALP element type");
  }
  const std::vector<std::uint8_t> body_bytes = body.Take();
  const auto source_sha = Sha256(input);
  const auto body_sha = Sha256(body_bytes);
  Writer archive;
  archive.Bytes(kMagic.data(), kMagic.size());
  archive.U32(kVersion);
  archive.U8(static_cast<std::uint8_t>(type));
  archive.U8(0);
  archive.U8(0);
  archive.U8(0);
  archive.U64(input.size() /
              (type == ElementType::kFloat32 ? sizeof(float) : sizeof(double)));
  archive.U64(input.size());
  archive.U32(0);
  archive.Bytes(source_sha.data(), source_sha.size());
  archive.Bytes(body_sha.data(), body_sha.size());
  archive.Bytes(body_bytes.data(), body_bytes.size());
  if (archive.bytes().size() < kHeaderSize) {
    throw Failure("internal ALP header size mismatch");
  }
  return archive.Take();
}

std::vector<std::uint8_t> DecodeArchive(
    const std::vector<std::uint8_t>& archive,
    Result* result) {
  if (archive.size() < kHeaderSize) {
    throw Failure("ALP archive header is truncated");
  }
  Reader header(archive);
  std::array<std::uint8_t, 8> magic{};
  header.Bytes(magic.data(), magic.size());
  if (magic != kMagic || header.U32() != kVersion) {
    throw Failure("ALP archive identity is invalid");
  }
  const auto type = static_cast<ElementType>(header.U8());
  if (header.U8() != 0 || header.U8() != 0 || header.U8() != 0) {
    throw Failure("ALP archive reserved header bytes are non-zero");
  }
  const std::uint64_t count = header.U64();
  const std::uint64_t original_bytes = header.U64();
  if (header.U32() != 0 ||
      (type != ElementType::kFloat32 && type != ElementType::kFloat64)) {
    throw Failure("ALP archive type or reserved word is invalid");
  }
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> source_sha{};
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> body_sha{};
  header.Bytes(source_sha.data(), source_sha.size());
  header.Bytes(body_sha.data(), body_sha.size());
  const std::vector<std::uint8_t> body_bytes(
      archive.begin() + static_cast<std::ptrdiff_t>(kHeaderSize), archive.end());
  if (Sha256(body_bytes) != body_sha) {
    throw Failure("ALP archive body SHA-256 mismatch");
  }
  const std::uint64_t element_width =
      type == ElementType::kFloat32 ? sizeof(float) : sizeof(double);
  if (count == 0 || count > std::numeric_limits<std::uint64_t>::max() /
                                  element_width ||
      count * element_width != original_bytes) {
    throw Failure("ALP archive typed length is invalid");
  }
  Reader body(body_bytes);
  std::vector<std::uint8_t> restored =
      type == ElementType::kFloat32
          ? DecompressColumn<float>(&body, count, result)
          : DecompressColumn<double>(&body, count, result);
  if (!body.done() || restored.size() != original_bytes ||
      Sha256(restored) != source_sha) {
    throw Failure("ALP archive did not restore the source SHA-256");
  }
  return restored;
}

}  // namespace

namespace pw::worldpack::alp_codec {

const char* Revision() { return kRevision; }

bool Run(const ElementType type,
         const std::string& input_path,
         const std::string& archive_path,
         const std::string& restored_path,
         Result* result,
         std::string* error) {
  if (result == nullptr || error == nullptr) {
    return false;
  }
  *result = {};
  error->clear();
  bool archive_written = false;
  bool restored_written = false;
  try {
    const std::vector<std::uint8_t> input = ReadFile(input_path);
    std::vector<std::uint8_t> archive = BuildArchive(type, input, result);
    WriteNewFile(archive_path, archive);
    archive_written = true;
    Result decoded_result;
    const std::vector<std::uint8_t> restored =
        DecodeArchive(archive, &decoded_result);
    if (restored != input || decoded_result.alp_vectors != result->alp_vectors ||
        decoded_result.alprd_vectors != result->alprd_vectors) {
      throw Failure("ALP byte restoration or vector accounting mismatch");
    }
    WriteNewFile(restored_path, restored);
    restored_written = true;
    std::vector<std::uint8_t> corrupt = archive;
    corrupt[kHeaderSize + (corrupt.size() - kHeaderSize) / 2] ^= 0x80;
    bool corruption_rejected = false;
    try {
      Result ignored;
      (void)DecodeArchive(corrupt, &ignored);
    } catch (const Failure&) {
      corruption_rejected = true;
    }
    if (!corruption_rejected) {
      throw Failure("ALP corrupt archive was accepted");
    }
    result->input_bytes = input.size();
    result->complete_persisted_bytes = archive.size();
    result->byte_equal = true;
    result->corruption_rejected = true;
    return true;
  } catch (const std::exception& caught) {
    *error = caught.what();
  } catch (...) {
    *error = "unknown ALP adapter failure";
  }
  std::error_code ignored;
  if (restored_written) {
    std::filesystem::remove(restored_path, ignored);
  }
  if (archive_written) {
    std::filesystem::remove(archive_path, ignored);
  }
  return false;
}

bool DecompressFile(const std::string& archive_path,
                    const std::string& restored_path,
                    Result* result,
                    std::string* error) {
  if (result == nullptr || error == nullptr) {
    return false;
  }
  *result = {};
  error->clear();
  try {
    const std::vector<std::uint8_t> archive = ReadFile(archive_path);
    const std::vector<std::uint8_t> restored =
        DecodeArchive(archive, result);
    WriteNewFile(restored_path, restored);
    result->input_bytes = restored.size();
    result->complete_persisted_bytes = archive.size();
    result->byte_equal = true;
    return true;
  } catch (const std::exception& caught) {
    *error = caught.what();
  } catch (...) {
    *error = "unknown ALP decompression failure";
  }
  return false;
}

}  // namespace pw::worldpack::alp_codec
