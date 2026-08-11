#include "descriptor_similarity_forest.h"
#include "pw_zpaq_bridge.h"

// The production bridge already includes the audited raw SQLite page locator.
// Including that bridge once here keeps the benchmark in the same translation
// unit as the internal locator without adding an app transform enum or ABI.
#include "../ios/Runner/pw_zpaq_bridge.cpp"

#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

constexpr std::array<std::uint8_t, 8> kContainerMagic = {'P', 'W', 'S', 'F',
                                                         'Z', '0', '1', 0};
constexpr std::size_t kContainerHeaderBytes = 32;

struct ArmResult {
  std::string name;
  std::uint64_t source_bytes = 0;
  std::uint64_t container_bytes = 0;
  std::uint64_t archive_bytes = 0;
  std::uint64_t sidecar_bytes = 0;
  std::uint64_t descriptor_nodes = 0;
  std::uint64_t root_nodes = 0;
  std::uint64_t predicted_nodes = 0;
  std::uint64_t verified_match_edges = 0;
  std::uint64_t elapsed_ms = 0;
  std::uint64_t peak_rss_bytes = 0;
  std::uint64_t peak_temp_bytes = 0;
  std::string archive_sha256;
  std::string transformed_sha256;
  std::string restored_sha256;
  bool source_unchanged = false;
  bool byte_equal = false;
  bool sha256_equal = false;
  bool integrity_ok = false;
  bool sidecar_equal = false;
  bool forest_valid = false;
};

int Fail(const std::string &message) {
  std::cerr << "PW_DESCRIPTOR_SIMILARITY_ZPAQ_BENCH_FAILED: " << message
            << '\n';
  return 1;
}

bool FileSize(const std::string &path, std::uint64_t *bytes) {
  struct stat status{};
  if (stat(path.c_str(), &status) != 0 || status.st_size < 0) {
    return false;
  }
  *bytes = static_cast<std::uint64_t>(status.st_size);
  return true;
}

bool Sha256Hex(const std::string &path, std::string *hex) {
  const int descriptor = open(path.c_str(), O_RDONLY);
  if (descriptor < 0) {
    return false;
  }
  struct stat status{};
  if (fstat(descriptor, &status) != 0 || status.st_size < 0 ||
      static_cast<std::uint64_t>(status.st_size) >
          std::numeric_limits<CC_LONG>::max()) {
    close(descriptor);
    return false;
  }
  const std::size_t length = static_cast<std::size_t>(status.st_size);
  void *mapping = nullptr;
  if (length != 0) {
    mapping = mmap(nullptr, length, PROT_READ, MAP_PRIVATE, descriptor, 0);
    if (mapping == MAP_FAILED) {
      close(descriptor);
      return false;
    }
  }
  std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
  const auto *bytes = length == 0 ? reinterpret_cast<const unsigned char *>("")
                                  : static_cast<const unsigned char *>(mapping);
  const bool hashed =
      CC_SHA256(bytes, static_cast<CC_LONG>(length), digest.data()) != nullptr;
  if (length != 0) {
    munmap(mapping, length);
  }
  close(descriptor);
  if (!hashed) {
    return false;
  }
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const unsigned char value : digest) {
    output << std::setw(2) << static_cast<unsigned int>(value);
  }
  *hex = output.str();
  return true;
}

bool FilesEqual(const std::string &left, const std::string &right) {
  std::ifstream left_stream(left, std::ios::binary);
  std::ifstream right_stream(right, std::ios::binary);
  if (!left_stream || !right_stream) {
    return false;
  }
  std::array<char, 1024 * 1024> left_buffer{};
  std::array<char, 1024 * 1024> right_buffer{};
  while (true) {
    left_stream.read(left_buffer.data(), left_buffer.size());
    right_stream.read(right_buffer.data(), right_buffer.size());
    const std::streamsize left_count = left_stream.gcount();
    const std::streamsize right_count = right_stream.gcount();
    if (left_count != right_count ||
        (left_count > 0 &&
         std::memcmp(left_buffer.data(), right_buffer.data(),
                     static_cast<std::size_t>(left_count)) != 0)) {
      return false;
    }
    if (left_count == 0) {
      return left_stream.eof() && right_stream.eof();
    }
  }
}

bool IntegrityOk(const std::string &path) {
  sqlite3 *database = nullptr;
  const std::string immutable_uri = "file:" + path + "?immutable=1";
  if (sqlite3_open_v2(immutable_uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                      nullptr) != SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }
  sqlite3_stmt *statement = nullptr;
  bool ok = sqlite3_prepare_v2(database, "PRAGMA integrity_check;", -1,
                               &statement, nullptr) == SQLITE_OK &&
            sqlite3_step(statement) == SQLITE_ROW;
  if (ok) {
    const char *result =
        reinterpret_cast<const char *>(sqlite3_column_text(statement, 0));
    ok = result != nullptr && std::strcmp(result, "ok") == 0;
  }
  if (statement != nullptr) {
    sqlite3_finalize(statement);
  }
  ok = sqlite3_close(database) == SQLITE_OK && ok;
  return ok;
}

std::uint64_t PeakRssBytes() {
  struct rusage usage{};
  return getrusage(RUSAGE_SELF, &usage) == 0
             ? static_cast<std::uint64_t>(usage.ru_maxrss)
             : 0;
}

std::uint64_t SumSizes(const std::vector<std::string> &paths) {
  std::uint64_t total = 0;
  for (const std::string &path : paths) {
    std::uint64_t size = 0;
    if (FileSize(path, &size)) {
      total += size;
    }
  }
  return total;
}

void WriteLittleEndian64(std::uint8_t *output, std::uint64_t value) {
  for (unsigned int shift = 0; shift < 64; shift += 8) {
    *output++ = static_cast<std::uint8_t>((value >> shift) & 0xffu);
  }
}

std::uint64_t ReadLittleEndian64(const std::uint8_t *input) {
  std::uint64_t value = 0;
  for (unsigned int shift = 0; shift < 64; shift += 8) {
    value |= static_cast<std::uint64_t>(*input++) << shift;
  }
  return value;
}

bool CopyStream(std::istream *input, std::ostream *output,
                std::uint64_t bytes) {
  std::array<char, 1024 * 1024> buffer{};
  while (bytes != 0) {
    const std::size_t chunk =
        static_cast<std::size_t>(std::min<std::uint64_t>(bytes, buffer.size()));
    input->read(buffer.data(), static_cast<std::streamsize>(chunk));
    if (input->gcount() != static_cast<std::streamsize>(chunk)) {
      return false;
    }
    output->write(buffer.data(), static_cast<std::streamsize>(chunk));
    if (!*output) {
      return false;
    }
    bytes -= chunk;
  }
  return true;
}

bool WriteContainer(const std::string &database_path,
                    const std::vector<std::uint8_t> &sidecar,
                    std::uint64_t descriptor_nodes,
                    const std::string &output_path) {
  std::uint64_t database_bytes = 0;
  if (!FileSize(database_path, &database_bytes)) {
    return false;
  }
  std::array<std::uint8_t, kContainerHeaderBytes> header{};
  std::copy(kContainerMagic.begin(), kContainerMagic.end(), header.begin());
  WriteLittleEndian64(header.data() + 8, database_bytes);
  WriteLittleEndian64(header.data() + 16, sidecar.size());
  WriteLittleEndian64(header.data() + 24, descriptor_nodes);

  std::ifstream database(database_path, std::ios::binary);
  std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
  if (!database || !output) {
    return false;
  }
  output.write(reinterpret_cast<const char *>(header.data()), header.size());
  if (!output || !CopyStream(&database, &output, database_bytes)) {
    return false;
  }
  if (!sidecar.empty()) {
    output.write(reinterpret_cast<const char *>(sidecar.data()),
                 static_cast<std::streamsize>(sidecar.size()));
  }
  output.flush();
  if (!output) {
    return false;
  }
  output.close();
  return SyncPath(output_path.c_str());
}

bool ReadContainer(const std::string &container_path,
                   const std::string &database_path,
                   std::vector<std::uint8_t> *sidecar,
                   std::uint64_t *descriptor_nodes) {
  std::uint64_t container_bytes = 0;
  if (!FileSize(container_path, &container_bytes) ||
      container_bytes < kContainerHeaderBytes) {
    return false;
  }
  std::ifstream input(container_path, std::ios::binary);
  std::array<std::uint8_t, kContainerHeaderBytes> header{};
  input.read(reinterpret_cast<char *>(header.data()), header.size());
  if (!input || !std::equal(kContainerMagic.begin(), kContainerMagic.end(),
                            header.begin())) {
    return false;
  }
  const std::uint64_t database_bytes = ReadLittleEndian64(header.data() + 8);
  const std::uint64_t sidecar_bytes = ReadLittleEndian64(header.data() + 16);
  *descriptor_nodes = ReadLittleEndian64(header.data() + 24);
  if (database_bytes > container_bytes - kContainerHeaderBytes ||
      sidecar_bytes !=
          container_bytes - kContainerHeaderBytes - database_bytes ||
      sidecar_bytes > std::numeric_limits<std::size_t>::max()) {
    return false;
  }

  std::ofstream database(database_path, std::ios::binary | std::ios::trunc);
  if (!database || !CopyStream(&input, &database, database_bytes)) {
    return false;
  }
  database.flush();
  database.close();
  if (!SyncPath(database_path.c_str())) {
    return false;
  }
  sidecar->resize(static_cast<std::size_t>(sidecar_bytes));
  if (sidecar_bytes != 0) {
    input.read(reinterpret_cast<char *>(sidecar->data()),
               static_cast<std::streamsize>(sidecar_bytes));
  }
  return input.good() || input.eof();
}

bool LocateAndReadDescriptors(const std::string &path,
                              std::vector<DescriptorLocation> *locations,
                              std::vector<std::uint8_t> *descriptors,
                              PWSQLiteDescriptorTransformStats *stats) {
  std::map<std::int64_t, DescriptorMetadata> metadata;
  std::uint32_t root_page = 0;
  if (!ReadSchemaAndMetadata(path, &root_page, &metadata)) {
    return false;
  }
  RandomAccessFile file(path);
  std::uint32_t page_size = 0;
  std::uint32_t reserved_bytes = 0;
  std::uint32_t page_count = 0;
  if (!file.valid() ||
      !ReadHeader(&file, &page_size, &reserved_bytes, &page_count)) {
    return false;
  }
  SQLiteDescriptorParser parser(&file, page_size, reserved_bytes, page_count,
                                metadata, stats);
  if (!parser.Parse(root_page, locations)) {
    return false;
  }
  std::sort(
      locations->begin(), locations->end(),
      [](const DescriptorLocation &left, const DescriptorLocation &right) {
        return left.row_id < right.row_id;
      });
  descriptors->clear();
  descriptors->reserve(static_cast<std::size_t>(stats->descriptor_bytes));
  for (const DescriptorLocation &location : *locations) {
    std::vector<unsigned char> row_bytes;
    if (!ReadSpans(&file, location.spans, &row_bytes) ||
        row_bytes.size() != location.rows * kDescriptorColumns) {
      return false;
    }
    descriptors->insert(descriptors->end(), row_bytes.begin(), row_bytes.end());
  }
  return descriptors->size() == stats->descriptor_bytes;
}

bool WriteDescriptors(const std::string &path,
                      const std::vector<DescriptorLocation> &locations,
                      const std::vector<std::uint8_t> &descriptors) {
  RandomAccessFile file(path);
  if (!file.valid()) {
    return false;
  }
  std::size_t cursor = 0;
  for (const DescriptorLocation &location : locations) {
    for (const PhysicalSpan &span : location.spans) {
      if (span.length > descriptors.size() - cursor ||
          !file.Write(span.offset, descriptors.data() + cursor, span.length)) {
        return false;
      }
      cursor += static_cast<std::size_t>(span.length);
    }
  }
  return cursor == descriptors.size() && file.Flush() && SyncPath(path.c_str());
}

bool SimilarityForward(const std::string &source,
                       const std::string &transformed,
                       std::vector<std::uint8_t> *sidecar,
                       pw::similarity_forest::Stats *forest_stats,
                       PWSQLiteDescriptorTransformStats *descriptor_stats,
                       std::string *error) {
  if (!CopyFile(source.c_str(), transformed.c_str())) {
    *error = pw_sqlite_descriptor_transform_last_error();
    return false;
  }
  std::vector<DescriptorLocation> locations;
  std::vector<std::uint8_t> descriptors;
  if (!LocateAndReadDescriptors(transformed, &locations, &descriptors,
                                descriptor_stats)) {
    *error = pw_sqlite_descriptor_transform_last_error();
    return false;
  }
  pw::similarity_forest::Options options;
  std::vector<std::uint64_t> parents;
  if (!pw::similarity_forest::Build(descriptors, options, &parents,
                                    forest_stats, error) ||
      !pw::similarity_forest::EncodeParents(parents, sidecar, error)) {
    return false;
  }
  std::vector<std::uint64_t> decoded_parents;
  if (!pw::similarity_forest::DecodeParents(*sidecar, parents.size(),
                                            &decoded_parents, error) ||
      decoded_parents != parents) {
    *error = "parent sidecar self-check failed: " + *error;
    return false;
  }
  if (!pw::similarity_forest::TransformResiduals(
          &descriptors, kDescriptorColumns, parents, false, error) ||
      !WriteDescriptors(transformed, locations, descriptors)) {
    if (error->empty()) {
      *error = pw_sqlite_descriptor_transform_last_error();
    }
    return false;
  }
  return true;
}

bool SimilarityInverse(const std::string &transformed,
                       const std::string &restored,
                       const std::vector<std::uint8_t> &sidecar,
                       std::uint64_t expected_nodes, std::string *error) {
  if (!CopyFile(transformed.c_str(), restored.c_str())) {
    *error = pw_sqlite_descriptor_transform_last_error();
    return false;
  }
  PWSQLiteDescriptorTransformStats descriptor_stats{};
  std::vector<DescriptorLocation> locations;
  std::vector<std::uint8_t> descriptors;
  if (!LocateAndReadDescriptors(restored, &locations, &descriptors,
                                &descriptor_stats)) {
    *error = pw_sqlite_descriptor_transform_last_error();
    return false;
  }
  const std::uint64_t actual_nodes = descriptors.size() / kDescriptorColumns;
  if (actual_nodes != expected_nodes) {
    *error = "container descriptor count mismatch";
    return false;
  }
  std::vector<std::uint64_t> parents;
  if (!pw::similarity_forest::DecodeParents(
          sidecar, static_cast<std::size_t>(expected_nodes), &parents, error) ||
      !pw::similarity_forest::TransformResiduals(
          &descriptors, kDescriptorColumns, parents, true, error) ||
      !WriteDescriptors(restored, locations, descriptors)) {
    if (error->empty()) {
      *error = pw_sqlite_descriptor_transform_last_error();
    }
    return false;
  }
  return true;
}

bool RunArm(const std::string &arm, const std::string &source,
            const std::string &run_directory,
            const std::string &source_sha256_before, ArmResult *result,
            std::string *error) {
  const std::string prefix = run_directory + "/" + arm;
  const std::string transformed = prefix + ".transformed.db";
  const std::string container = prefix + ".container";
  const std::string archive = prefix + ".zpaq";
  const std::string decoded_container = prefix + ".decoded.container";
  const std::string decoded_database = prefix + ".decoded.db";
  const std::string restored = prefix + ".restored.db";
  const auto started = std::chrono::steady_clock::now();

  result->name = arm;
  if (!FileSize(source, &result->source_bytes)) {
    *error = "source size failed";
    return false;
  }
  PWSQLiteDescriptorTransformStats forward_stats{};
  PWSQLiteDescriptorTransformStats inverse_stats{};
  pw::similarity_forest::Stats forest_stats{};
  std::vector<std::uint8_t> sidecar;
  if (arm == "track_delta_v1") {
    if (pw_sqlite_descriptor_transform_file(source.c_str(), transformed.c_str(),
                                            PW_SQLITE_DESCRIPTOR_TRACK_DELTA, 0,
                                            &forward_stats) !=
        PW_SQLITE_DESCRIPTOR_TRANSFORM_OK) {
      *error = pw_sqlite_descriptor_transform_last_error();
      return false;
    }
    result->descriptor_nodes = 1251246;
    result->predicted_nodes = forward_stats.predicted_descriptor_nodes;
    result->root_nodes = result->descriptor_nodes - result->predicted_nodes;
    result->verified_match_edges = forward_stats.verified_match_edges;
  } else if (arm == "similarity_forest_v1") {
    std::cout << "PW_SIMILARITY_FOREST_BUILD_STARTED\n" << std::flush;
    if (!SimilarityForward(source, transformed, &sidecar, &forest_stats,
                           &forward_stats, error)) {
      return false;
    }
    std::cout << "PW_SIMILARITY_FOREST_BUILD_COMPLETE nodes="
              << forest_stats.descriptor_nodes
              << " predicted=" << forest_stats.predicted_nodes
              << " sidecar=" << sidecar.size() << '\n'
              << std::flush;
    result->descriptor_nodes = forest_stats.descriptor_nodes;
    result->root_nodes = forest_stats.root_nodes;
    result->predicted_nodes = forest_stats.predicted_nodes;
  } else {
    *error = "unknown arm";
    return false;
  }
  result->sidecar_bytes = sidecar.size();
  if (!IntegrityOk(transformed) ||
      !Sha256Hex(transformed, &result->transformed_sha256) ||
      !WriteContainer(transformed, sidecar, result->descriptor_nodes,
                      container) ||
      !FileSize(container, &result->container_bytes)) {
    *error = "transformed database or container validation failed";
    return false;
  }

  std::cout << "PW_" << arm << "_ZPAQ_STARTED\n" << std::flush;
  std::uint64_t generation = pw_zpaq_cancellation_generation();
  int32_t zpaq_status =
      pw_zpaq_compress_file(container.c_str(), archive.c_str(), 5, generation);
  if (zpaq_status != PW_ZPAQ_OK) {
    *error = std::string("ZPAQ compression failed: ") +
             pw_zpaq_error_message(zpaq_status) + " " + pw_zpaq_last_error();
    return false;
  }
  generation = pw_zpaq_cancellation_generation();
  zpaq_status = pw_zpaq_decompress_file(archive.c_str(),
                                        decoded_container.c_str(), generation);
  if (zpaq_status != PW_ZPAQ_OK) {
    *error = std::string("ZPAQ decompression failed: ") +
             pw_zpaq_error_message(zpaq_status) + " " + pw_zpaq_last_error();
    return false;
  }
  std::vector<std::uint8_t> decoded_sidecar;
  std::uint64_t decoded_descriptor_nodes = 0;
  if (!ReadContainer(decoded_container, decoded_database, &decoded_sidecar,
                     &decoded_descriptor_nodes)) {
    *error = "decoded container validation failed";
    return false;
  }
  result->sidecar_equal = decoded_sidecar == sidecar;
  result->forest_valid = decoded_descriptor_nodes == result->descriptor_nodes;

  if (arm == "track_delta_v1") {
    if (!decoded_sidecar.empty() ||
        pw_sqlite_descriptor_transform_file(
            decoded_database.c_str(), restored.c_str(),
            PW_SQLITE_DESCRIPTOR_TRACK_DELTA, 1,
            &inverse_stats) != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK ||
        std::memcmp(&forward_stats, &inverse_stats, sizeof(forward_stats)) !=
            0) {
      *error = std::string("track inverse failed: ") +
               pw_sqlite_descriptor_transform_last_error();
      return false;
    }
  } else if (!SimilarityInverse(decoded_database, restored, decoded_sidecar,
                                decoded_descriptor_nodes, error)) {
    return false;
  }

  std::uint64_t source_bytes_after = 0;
  std::uint64_t restored_bytes = 0;
  std::string source_sha256_after;
  if (!FileSize(archive, &result->archive_bytes) ||
      !FileSize(source, &source_bytes_after) ||
      !FileSize(restored, &restored_bytes) ||
      !Sha256Hex(archive, &result->archive_sha256) ||
      !Sha256Hex(source, &source_sha256_after) ||
      !Sha256Hex(restored, &result->restored_sha256)) {
    *error = "output identity measurement failed";
    return false;
  }
  result->source_unchanged = source_bytes_after == result->source_bytes &&
                             source_sha256_after == source_sha256_before;
  result->byte_equal =
      restored_bytes == result->source_bytes && FilesEqual(source, restored);
  result->sha256_equal = result->restored_sha256 == source_sha256_before;
  result->integrity_ok = IntegrityOk(restored);
  result->elapsed_ms = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started)
          .count());
  result->peak_rss_bytes = PeakRssBytes();
  result->peak_temp_bytes =
      SumSizes({transformed, container, archive, decoded_container,
                decoded_database, restored});
  if (!result->source_unchanged || !result->byte_equal ||
      !result->sha256_equal || !result->integrity_ok ||
      !result->sidecar_equal || !result->forest_valid) {
    *error = "one or more exactness gates failed";
    return false;
  }
  std::cout << "PW_" << arm << "_COMPLETE archive=" << result->archive_bytes
            << '\n'
            << std::flush;
  return true;
}

void AppendArmJson(const ArmResult &arm, std::ostream *output) {
  *output << "{\"archive_bytes\":" << arm.archive_bytes
          << ",\"archive_sha256\":\"" << arm.archive_sha256
          << "\",\"container_bytes\":" << arm.container_bytes
          << ",\"transformed_sha256\":\"" << arm.transformed_sha256
          << "\",\"restored_sha256\":\"" << arm.restored_sha256
          << "\",\"parent_sidecar_bytes\":" << arm.sidecar_bytes
          << ",\"descriptor_nodes\":" << arm.descriptor_nodes
          << ",\"root_nodes\":" << arm.root_nodes
          << ",\"predicted_descriptor_nodes\":" << arm.predicted_nodes
          << ",\"verified_match_edges\":" << arm.verified_match_edges
          << ",\"source_unchanged\":" << (arm.source_unchanged ? 1 : 0)
          << ",\"byte_equal\":" << (arm.byte_equal ? 1 : 0)
          << ",\"sha256_equal\":" << (arm.sha256_equal ? 1 : 0)
          << ",\"sqlite_integrity_ok\":" << (arm.integrity_ok ? 1 : 0)
          << ",\"sidecar_equal\":" << (arm.sidecar_equal ? 1 : 0)
          << ",\"forest_valid\":" << (arm.forest_valid ? 1 : 0)
          << ",\"elapsed_ms\":" << arm.elapsed_ms
          << ",\"peak_rss_bytes\":" << arm.peak_rss_bytes
          << ",\"peak_temp_bytes\":" << arm.peak_temp_bytes << "}";
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 4) {
    return Fail("usage: bench <source.db> <run-directory> <result.json>");
  }
  const std::string source = argv[1];
  const std::string run_directory = argv[2];
  const std::string result_path = argv[3];
  if (std::strcmp(pw_zpaq_version(), "7.15") != 0 ||
      std::strcmp(
          pw_zpaq_revision(),
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") !=
          0) {
    return Fail("unexpected ZPAQ identity");
  }
  std::uint64_t source_bytes = 0;
  std::string source_sha256_before;
  if (!FileSize(source, &source_bytes) || source_bytes != 198983680 ||
      !Sha256Hex(source, &source_sha256_before) ||
      source_sha256_before !=
          "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0" ||
      !IntegrityOk(source)) {
    return Fail("immutable source identity or integrity failed");
  }

  ArmResult arm_a;
  ArmResult arm_b;
  std::string error;
  if (!RunArm("track_delta_v1", source, run_directory, source_sha256_before,
              &arm_a, &error)) {
    return Fail("arm A: " + error);
  }
  if (!RunArm("similarity_forest_v1", source, run_directory,
              source_sha256_before, &arm_b, &error)) {
    return Fail("arm B: " + error);
  }

  const bool b_smaller = arm_b.archive_bytes < arm_a.archive_bytes;
  const std::int64_t delta_bytes =
      static_cast<std::int64_t>(arm_b.archive_bytes) -
      static_cast<std::int64_t>(arm_a.archive_bytes);
  const double delta_fraction = static_cast<double>(delta_bytes) /
                                static_cast<double>(arm_a.archive_bytes);
  std::ofstream output(result_path, std::ios::trunc);
  if (!output) {
    return Fail("could not create result JSON");
  }
  output << "{\"schema\":\"pw_descriptor_similarity_forest_zpaq_result_v1\""
         << ",\"source_bytes\":" << source_bytes << ",\"source_sha256\":\""
         << source_sha256_before << "\""
         << ",\"zpaq_version\":\"7.15\",\"zpaq_method\":5"
         << ",\"faiss_version\":\"1.14.0\""
         << ",\"faiss_parameters\":{\"dimension\":128,\"seed\":20260802"
         << ",\"nlist\":2048,\"nprobe\":32"
         << ",\"block_descriptors\":8192"
         << ",\"maximum_training_descriptors\":131072"
         << ",\"nearest_candidates\":1}"
         << ",\"arm_a\":";
  AppendArmJson(arm_a, &output);
  output << ",\"arm_b\":";
  AppendArmJson(arm_b, &output);
  output << ",\"b_minus_a_bytes\":" << delta_bytes
         << ",\"b_minus_a_fraction\":" << std::setprecision(12)
         << delta_fraction << ",\"b_strictly_smaller\":" << (b_smaller ? 1 : 0)
         << ",\"local_research_baseline\":\""
         << (b_smaller ? "similarity_forest_v1" : "track_delta_v1")
         << "\",\"production_promoted\":0}" << '\n';
  output.flush();
  if (!output) {
    return Fail("result JSON write failed");
  }
  std::cout << "PW_DESCRIPTOR_SIMILARITY_ZPAQ_AB_COMPLETE result="
            << result_path << '\n';
  return 0;
}
