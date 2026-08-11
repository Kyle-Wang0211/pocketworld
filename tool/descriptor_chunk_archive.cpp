#include "descriptor_chunk_archive.h"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <utility>

namespace pw::descriptor_chunk {
namespace {

constexpr std::array<std::uint8_t, 8> kMagic = {'P', 'W', 'D', 'C',
                                                'A', '0', '1', 0};
constexpr std::uint8_t kVersion = 1;

bool Fail(std::string message, std::string *error) {
  if (error != nullptr) {
    *error = std::move(message);
  }
  return false;
}

void Write32(std::uint8_t *output, std::uint32_t value) {
  for (unsigned int shift = 0; shift < 32; shift += 8) {
    *output++ = static_cast<std::uint8_t>((value >> shift) & 0xffu);
  }
}

void Write64(std::uint8_t *output, std::uint64_t value) {
  for (unsigned int shift = 0; shift < 64; shift += 8) {
    *output++ = static_cast<std::uint8_t>((value >> shift) & 0xffu);
  }
}

std::uint32_t Read32(const std::uint8_t *input) {
  std::uint32_t value = 0;
  for (unsigned int shift = 0; shift < 32; shift += 8) {
    value |= static_cast<std::uint32_t>(*input++) << shift;
  }
  return value;
}

std::uint64_t Read64(const std::uint8_t *input) {
  std::uint64_t value = 0;
  for (unsigned int shift = 0; shift < 64; shift += 8) {
    value |= static_cast<std::uint64_t>(*input++) << shift;
  }
  return value;
}

} // namespace

std::array<std::uint8_t, 32> Sha256(const std::vector<std::uint8_t> &bytes) {
  std::array<std::uint8_t, 32> digest{};
  CC_SHA256(bytes.empty() ? reinterpret_cast<const void *>("") : bytes.data(),
            static_cast<CC_LONG>(bytes.size()), digest.data());
  return digest;
}

bool BuildArchive(const ArchiveFields &fields,
                  const std::vector<std::uint8_t> &frame,
                  const std::vector<std::uint8_t> &parents,
                  std::vector<std::uint8_t> *archive, std::string *error) {
  if (archive == nullptr || fields.backend == 0 ||
      fields.descriptor_count == 0 || fields.dimension == 0 ||
      fields.root_count == 0 || fields.root_count >= fields.descriptor_count ||
      frame.empty() || parents.empty()) {
    return Fail("archive fields or outputs are invalid", error);
  }
  if (frame.size() > std::numeric_limits<std::uint64_t>::max() ||
      parents.size() > std::numeric_limits<std::uint64_t>::max() ||
      frame.size() >
          std::numeric_limits<std::size_t>::max() - kArchiveHeaderBytes ||
      parents.size() > std::numeric_limits<std::size_t>::max() -
                           kArchiveHeaderBytes - frame.size()) {
    return Fail("archive size overflows", error);
  }

  archive->assign(kArchiveHeaderBytes + frame.size() + parents.size(), 0);
  std::copy(kMagic.begin(), kMagic.end(), archive->begin());
  (*archive)[8] = kVersion;
  (*archive)[9] = fields.backend;
  Write32(archive->data() + 12, fields.descriptor_count);
  Write32(archive->data() + 16, fields.dimension);
  Write32(archive->data() + 20, fields.root_count);
  Write64(archive->data() + 24, frame.size());
  Write64(archive->data() + 32, parents.size());
  std::copy(fields.transformed_sha256.begin(), fields.transformed_sha256.end(),
            archive->begin() + 40);
  std::copy(fields.original_sha256.begin(), fields.original_sha256.end(),
            archive->begin() + 72);
  const auto parent_sha = Sha256(parents);
  std::copy(parent_sha.begin(), parent_sha.end(), archive->begin() + 104);
  const auto frame_sha = Sha256(frame);
  std::copy(frame_sha.begin(), frame_sha.end(), archive->begin() + 136);
  std::copy(frame.begin(), frame.end(), archive->begin() + kArchiveHeaderBytes);
  std::copy(parents.begin(), parents.end(),
            archive->begin() + kArchiveHeaderBytes + frame.size());
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

bool ParseArchive(const std::vector<std::uint8_t> &archive,
                  ParsedArchive *parsed, std::string *error) {
  if (parsed == nullptr || archive.size() < kArchiveHeaderBytes ||
      !std::equal(kMagic.begin(), kMagic.end(), archive.begin()) ||
      archive[8] != kVersion || archive[9] == 0) {
    return Fail("archive header is invalid", error);
  }
  const std::uint64_t frame_size = Read64(archive.data() + 24);
  const std::uint64_t parent_size = Read64(archive.data() + 32);
  if (frame_size > archive.size() - kArchiveHeaderBytes ||
      parent_size != archive.size() - kArchiveHeaderBytes - frame_size) {
    return Fail("archive section sizes are invalid", error);
  }

  ParsedArchive candidate;
  candidate.fields.backend = archive[9];
  candidate.fields.descriptor_count = Read32(archive.data() + 12);
  candidate.fields.dimension = Read32(archive.data() + 16);
  candidate.fields.root_count = Read32(archive.data() + 20);
  if (candidate.fields.descriptor_count == 0 ||
      candidate.fields.dimension == 0 || candidate.fields.root_count == 0 ||
      candidate.fields.root_count >= candidate.fields.descriptor_count) {
    return Fail("archive descriptor dimensions are invalid", error);
  }
  std::copy_n(archive.begin() + 40, 32,
              candidate.fields.transformed_sha256.begin());
  std::copy_n(archive.begin() + 72, 32,
              candidate.fields.original_sha256.begin());
  std::array<std::uint8_t, 32> expected_parent_sha{};
  std::copy_n(archive.begin() + 104, 32, expected_parent_sha.begin());
  std::array<std::uint8_t, 32> expected_frame_sha{};
  std::copy_n(archive.begin() + 136, 32, expected_frame_sha.begin());
  candidate.frame.assign(archive.begin() + kArchiveHeaderBytes,
                         archive.begin() + kArchiveHeaderBytes + frame_size);
  candidate.parents.assign(archive.begin() + kArchiveHeaderBytes + frame_size,
                           archive.end());
  if (candidate.frame.empty() || candidate.parents.empty() ||
      Sha256(candidate.frame) != expected_frame_sha ||
      Sha256(candidate.parents) != expected_parent_sha) {
    return Fail("archive frame or parent sidecar failed SHA-256", error);
  }
  candidate.complete_persisted_bytes = archive.size();
  *parsed = std::move(candidate);
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

bool VerifyDecoded(const ParsedArchive &archive,
                   const std::vector<std::uint8_t> &transformed,
                   const std::vector<std::uint8_t> &original,
                   std::string *error) {
  const std::uint64_t expected_bytes =
      static_cast<std::uint64_t>(archive.fields.descriptor_count) *
      archive.fields.dimension;
  if (expected_bytes != transformed.size() ||
      expected_bytes != original.size() ||
      Sha256(transformed) != archive.fields.transformed_sha256 ||
      Sha256(original) != archive.fields.original_sha256) {
    return Fail("decoded descriptor bytes failed size or SHA-256 gates", error);
  }
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

} // namespace pw::descriptor_chunk
