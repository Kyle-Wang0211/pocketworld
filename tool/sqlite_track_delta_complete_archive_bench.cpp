#include "pw_sqlite_descriptor_transform.h"
#include "pw_zpaq_bridge.h"

#include <CommonCrypto/CommonDigest.h>
#include <sqlite3.h>

#include <array>
#include <chrono>
#include <cstdlib>
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

bool FileSize(const std::string& path, uint64_t* bytes) {
  struct stat status {};
  if (stat(path.c_str(), &status) != 0 || status.st_size < 0) {
    return false;
  }
  *bytes = static_cast<uint64_t>(status.st_size);
  return true;
}

bool Sha256Hex(const std::string& path, std::string* hex) {
  const int descriptor = open(path.c_str(), O_RDONLY);
  if (descriptor < 0) {
    return false;
  }
  struct stat status {};
  if (fstat(descriptor, &status) != 0 || status.st_size < 0 ||
      static_cast<uint64_t>(status.st_size) >
          std::numeric_limits<CC_LONG>::max()) {
    close(descriptor);
    return false;
  }

  const size_t length = static_cast<size_t>(status.st_size);
  void* mapping = nullptr;
  if (length != 0) {
    mapping = mmap(nullptr, length, PROT_READ, MAP_PRIVATE, descriptor, 0);
    if (mapping == MAP_FAILED) {
      close(descriptor);
      return false;
    }
  }
  std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
  const auto* bytes = length == 0
                          ? reinterpret_cast<const unsigned char*>("")
                          : static_cast<const unsigned char*>(mapping);
  const bool hashed = CC_SHA256(bytes, static_cast<CC_LONG>(length),
                                digest.data()) != nullptr;
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

bool FilesEqual(const std::string& left, const std::string& right) {
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
                     static_cast<size_t>(left_count)) != 0)) {
      return false;
    }
    if (left_count == 0) {
      return left_stream.eof() && right_stream.eof();
    }
  }
}

bool IntegrityOk(const std::string& path) {
  sqlite3* database = nullptr;
  const std::string immutable_uri = "file:" + path + "?immutable=1";
  if (sqlite3_open_v2(immutable_uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr) !=
      SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }
  sqlite3_stmt* statement = nullptr;
  bool ok = sqlite3_prepare_v2(database, "PRAGMA integrity_check;", -1,
                               &statement, nullptr) == SQLITE_OK &&
            sqlite3_step(statement) == SQLITE_ROW;
  if (ok) {
    const char* result = reinterpret_cast<const char*>(
        sqlite3_column_text(statement, 0));
    ok = result != nullptr && std::strcmp(result, "ok") == 0;
  }
  if (statement != nullptr) {
    sqlite3_finalize(statement);
  }
  ok = sqlite3_close(database) == SQLITE_OK && ok;
  return ok;
}

uint64_t PeakRssBytes() {
  struct rusage usage {};
  return getrusage(RUSAGE_SELF, &usage) == 0
             ? static_cast<uint64_t>(usage.ru_maxrss)
             : 0;
}

uint64_t SumExistingSizes(const std::vector<std::string>& paths) {
  uint64_t total = 0;
  for (const std::string& path : paths) {
    uint64_t size = 0;
    if (FileSize(path, &size)) {
      total += size;
    }
  }
  return total;
}

bool AppendAndSync(const std::string& path, const std::string& record) {
  {
    std::ofstream output(path, std::ios::app);
    if (!output) {
      return false;
    }
    output << record << '\n';
    output.flush();
    if (!output) {
      return false;
    }
  }
  const int descriptor = open(path.c_str(), O_RDONLY);
  if (descriptor < 0) {
    return false;
  }
  const bool synced = fsync(descriptor) == 0;
  close(descriptor);
  return synced;
}

int Fail(const std::string& message) {
  std::cerr << "PW_SQLITE_TRACK_ARCHIVE_BENCH_FAILED: " << message << '\n';
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 6) {
    return Fail("usage: bench <arm> <input> <run-dir> <repeat> <result-log>");
  }
  const std::string arm = argv[1];
  const std::string source = argv[2];
  const std::string run_directory = argv[3];
  const int repeat = std::atoi(argv[4]);
  const std::string result_log = argv[5];
  if ((arm != "raw" && arm != "track_delta_v1" &&
       arm != "exact_transform_v2") ||
      repeat <= 0) {
    return Fail("invalid arm or repeat");
  }
  if (std::strcmp(pw_zpaq_version(), "7.15") != 0 ||
      std::strcmp(
          pw_zpaq_revision(),
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") !=
          0) {
    return Fail("unexpected ZPAQ identity");
  }

  const std::string prefix = run_directory + "/" + arm;
  const std::string transformed = prefix + ".transformed.db";
  const std::string archive = prefix + ".zpaq";
  const std::string decoded = prefix + ".decoded.db";
  const std::string restored = prefix + ".restored.db";

  uint64_t source_bytes = 0;
  std::string source_sha256_before;
  if (!FileSize(source, &source_bytes) ||
      !Sha256Hex(source, &source_sha256_before) || !IntegrityOk(source)) {
    return Fail("source identity or integrity failed");
  }

  const auto started = std::chrono::steady_clock::now();
  PWSQLiteDescriptorTransformStats forward_stats{};
  PWSQLiteDescriptorTransformStats inverse_stats{};
  std::string compression_input = source;
  std::string transformed_sha256 = source_sha256_before;
  if (arm == "track_delta_v1" || arm == "exact_transform_v2") {
    const int32_t transform = arm == "exact_transform_v2"
                                  ? PW_SQLITE_EXACT_TRANSFORM_V2
                                  : PW_SQLITE_DESCRIPTOR_TRACK_DELTA;
    const int32_t status = pw_sqlite_descriptor_transform_file(
        source.c_str(), transformed.c_str(), transform, 0, &forward_stats);
    if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK ||
        !Sha256Hex(transformed, &transformed_sha256) ||
        !IntegrityOk(transformed)) {
      return Fail(std::string("forward track transform failed: ") +
                  pw_sqlite_descriptor_transform_last_error());
    }
    compression_input = transformed;
  }

  uint64_t generation = pw_zpaq_cancellation_generation();
  int32_t zpaq_status = pw_zpaq_compress_file(
      compression_input.c_str(), archive.c_str(), 5, generation);
  if (zpaq_status != PW_ZPAQ_OK) {
    return Fail(std::string("ZPAQ compression failed: ") +
                pw_zpaq_error_message(zpaq_status) + " " +
                pw_zpaq_last_error());
  }
  generation = pw_zpaq_cancellation_generation();
  zpaq_status = pw_zpaq_decompress_file(archive.c_str(), decoded.c_str(),
                                        generation);
  if (zpaq_status != PW_ZPAQ_OK) {
    return Fail(std::string("ZPAQ decompression failed: ") +
                pw_zpaq_error_message(zpaq_status) + " " +
                pw_zpaq_last_error());
  }

  std::string final_database = decoded;
  if (arm == "track_delta_v1" || arm == "exact_transform_v2") {
    const int32_t transform = arm == "exact_transform_v2"
                                  ? PW_SQLITE_EXACT_TRANSFORM_V2
                                  : PW_SQLITE_DESCRIPTOR_TRACK_DELTA;
    const int32_t status = pw_sqlite_descriptor_transform_file(
        decoded.c_str(), restored.c_str(), transform, 1, &inverse_stats);
    if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK) {
      return Fail(std::string("inverse track transform failed: ") +
                  pw_sqlite_descriptor_transform_last_error());
    }
    final_database = restored;
  }

  uint64_t archive_bytes = 0;
  uint64_t restored_bytes = 0;
  uint64_t source_bytes_after = 0;
  std::string archive_sha256;
  std::string restored_sha256;
  std::string source_sha256_after;
  if (!FileSize(archive, &archive_bytes) ||
      !FileSize(final_database, &restored_bytes) ||
      !FileSize(source, &source_bytes_after) ||
      !Sha256Hex(archive, &archive_sha256) ||
      !Sha256Hex(final_database, &restored_sha256) ||
      !Sha256Hex(source, &source_sha256_after)) {
    return Fail("output identity measurement failed");
  }

  const bool source_unchanged = source_bytes_after == source_bytes &&
                                source_sha256_after == source_sha256_before;
  const bool byte_equal = restored_bytes == source_bytes &&
                          FilesEqual(source, final_database);
  const bool sha256_equal = restored_sha256 == source_sha256_before;
  const bool integrity_ok = IntegrityOk(final_database);
  const bool stats_equal =
      arm == "raw" ||
      std::memcmp(&forward_stats, &inverse_stats, sizeof(forward_stats)) == 0;
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started);
  const uint64_t peak_temp_bytes = SumExistingSizes(
      {transformed, archive, decoded, restored});

  std::ostringstream record;
  record << "{\"repeat\":" << repeat << ",\"arm\":\"" << arm
         << "\",\"source_bytes\":" << source_bytes
         << ",\"archive_bytes\":" << archive_bytes
         << ",\"archive_sha256\":\"" << archive_sha256
         << "\",\"transformed_sha256\":\"" << transformed_sha256
         << "\",\"restored_sha256\":\"" << restored_sha256
         << "\",\"source_unchanged\":" << (source_unchanged ? 1 : 0)
         << ",\"byte_equal\":" << (byte_equal ? 1 : 0)
         << ",\"sha256_equal\":" << (sha256_equal ? 1 : 0)
         << ",\"integrity_ok\":" << (integrity_ok ? 1 : 0)
         << ",\"stats_equal\":" << (stats_equal ? 1 : 0)
         << ",\"verified_match_edges\":"
         << forward_stats.verified_match_edges
         << ",\"matched_descriptor_nodes\":"
         << forward_stats.matched_descriptor_nodes
         << ",\"predicted_descriptor_nodes\":"
         << forward_stats.predicted_descriptor_nodes
         << ",\"keypoint_records\":" << forward_stats.keypoint_records
         << ",\"keypoint_bytes\":" << forward_stats.keypoint_bytes
         << ",\"match_records\":" << forward_stats.match_records
         << ",\"match_bytes\":" << forward_stats.match_bytes
         << ",\"two_view_records\":" << forward_stats.two_view_records
         << ",\"two_view_bytes\":" << forward_stats.two_view_bytes
         << ",\"elapsed_ms\":" << elapsed.count()
         << ",\"peak_rss_bytes\":" << PeakRssBytes()
         << ",\"peak_temp_bytes\":" << peak_temp_bytes << "}";

  if (!AppendAndSync(result_log, record.str())) {
    return Fail("durable result append failed");
  }
  std::cout << record.str() << '\n';
  if (!source_unchanged || !byte_equal || !sha256_equal || !integrity_ok ||
      !stats_equal) {
    return Fail("one or more exactness gates failed");
  }
  return 0;
}
