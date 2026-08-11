#ifndef POCKETWORLD_TOOL_DESCRIPTOR_CHUNK_ARCHIVE_H_
#define POCKETWORLD_TOOL_DESCRIPTOR_CHUNK_ARCHIVE_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pw::descriptor_chunk {

constexpr std::size_t kArchiveHeaderBytes = 176;

struct ArchiveFields {
  std::uint8_t backend = 0;
  std::uint32_t descriptor_count = 0;
  std::uint32_t dimension = 0;
  std::uint32_t root_count = 0;
  std::array<std::uint8_t, 32> transformed_sha256{};
  std::array<std::uint8_t, 32> original_sha256{};
};

struct ParsedArchive {
  ArchiveFields fields;
  std::vector<std::uint8_t> frame;
  std::vector<std::uint8_t> parents;
  std::size_t complete_persisted_bytes = 0;
};

std::array<std::uint8_t, 32> Sha256(const std::vector<std::uint8_t> &bytes);

bool BuildArchive(const ArchiveFields &fields,
                  const std::vector<std::uint8_t> &frame,
                  const std::vector<std::uint8_t> &parents,
                  std::vector<std::uint8_t> *archive, std::string *error);

bool ParseArchive(const std::vector<std::uint8_t> &archive,
                  ParsedArchive *parsed, std::string *error);

bool VerifyDecoded(const ParsedArchive &archive,
                   const std::vector<std::uint8_t> &transformed,
                   const std::vector<std::uint8_t> &original,
                   std::string *error);

} // namespace pw::descriptor_chunk

#endif // POCKETWORLD_TOOL_DESCRIPTOR_CHUNK_ARCHIVE_H_
