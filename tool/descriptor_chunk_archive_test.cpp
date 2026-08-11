#include "descriptor_chunk_archive.h"

#include <array>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

int Fail(const std::string &message) {
  std::cerr << "PW_DESCRIPTOR_CHUNK_ARCHIVE_TEST_FAILED: " << message << '\n';
  return 1;
}

} // namespace

int main() {
  std::vector<std::uint8_t> frame(257);
  std::vector<std::uint8_t> parents(31);
  std::vector<std::uint8_t> transformed(512);
  std::vector<std::uint8_t> original(512);
  for (std::size_t index = 0; index < frame.size(); ++index) {
    frame[index] = static_cast<std::uint8_t>(index * 17u);
  }
  for (std::size_t index = 0; index < parents.size(); ++index) {
    parents[index] = static_cast<std::uint8_t>(index * 7u);
  }
  for (std::size_t index = 0; index < transformed.size(); ++index) {
    transformed[index] = static_cast<std::uint8_t>(index * 11u);
    original[index] = static_cast<std::uint8_t>(index * 13u);
  }

  pw::descriptor_chunk::ArchiveFields fields;
  fields.backend = 7;
  fields.descriptor_count = 4;
  fields.dimension = 128;
  fields.root_count = 2;
  fields.transformed_sha256 = pw::descriptor_chunk::Sha256(transformed);
  fields.original_sha256 = pw::descriptor_chunk::Sha256(original);

  std::vector<std::uint8_t> archive;
  std::string error;
  if (!pw::descriptor_chunk::BuildArchive(fields, frame, parents, &archive,
                                          &error)) {
    return Fail(error);
  }

  pw::descriptor_chunk::ParsedArchive parsed;
  if (!pw::descriptor_chunk::ParseArchive(archive, &parsed, &error)) {
    return Fail(error);
  }
  if (parsed.fields.backend != fields.backend || parsed.frame != frame ||
      parsed.parents != parents ||
      parsed.complete_persisted_bytes != archive.size()) {
    return Fail("parsed archive fields differ");
  }
  if (!pw::descriptor_chunk::VerifyDecoded(parsed, transformed, original,
                                           &error)) {
    return Fail(error);
  }

  transformed[9] ^= 1u;
  if (pw::descriptor_chunk::VerifyDecoded(parsed, transformed, original,
                                          &error)) {
    return Fail("changed transformed bytes passed SHA-256 gate");
  }

  archive.back() ^= 1u;
  if (pw::descriptor_chunk::ParseArchive(archive, &parsed, &error)) {
    return Fail("changed parent sidecar passed archive gate");
  }

  if (!pw::descriptor_chunk::BuildArchive(fields, frame, parents, &archive,
                                          &error)) {
    return Fail(error);
  }
  archive[pw::descriptor_chunk::kArchiveHeaderBytes + frame.size() / 2] ^= 1u;
  if (pw::descriptor_chunk::ParseArchive(archive, &parsed, &error)) {
    return Fail("changed codec frame passed archive gate");
  }

  std::cout << "PW_DESCRIPTOR_CHUNK_ARCHIVE_TEST_OK\n";
  return 0;
}
