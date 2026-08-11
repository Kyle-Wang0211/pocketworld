#include "pwa2_sqlite_logical_archive.h"
#include "pw_zpaq_bridge.h"

#include <CommonCrypto/CommonDigest.h>
#include <sqlite3.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

constexpr std::uint64_t kMaximumAcceptedBytes = 111961726;
constexpr char kContainerMagic[] = "PWA2ZP01";

struct ContainerEntry {
  std::string name;
  std::uint64_t raw_size = 0;
  std::uint64_t compressed_size = 0;
  std::uint64_t payload_offset = 0;
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> raw_sha{};
  std::filesystem::path archive_path;
};

struct DescriptorRequest {
  std::int64_t image_id = 0;
  std::int64_t row = 0;
  std::array<std::uint8_t, 128> expected{};
};

int Fail(const std::string& message) {
  std::cerr << "PW_PWA2_STRUCTURE_ZPAQ_BENCH_FAILED: " << message << '\n';
  return 1;
}

bool FileSize(const std::filesystem::path& path, std::uint64_t* size) {
  struct stat status {};
  if (stat(path.c_str(), &status) != 0 || status.st_size < 0) {
    return false;
  }
  *size = static_cast<std::uint64_t>(status.st_size);
  return true;
}

std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> Sha256Bytes(
    const std::vector<std::uint8_t>& bytes) {
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> digest{};
  CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest.data());
  return digest;
}

bool Sha256File(
    const std::filesystem::path& path,
    std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH>* digest) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    return false;
  }
  CC_SHA256_CTX context{};
  CC_SHA256_Init(&context);
  std::array<char, 1024 * 1024> buffer{};
  while (input) {
    input.read(buffer.data(), buffer.size());
    const std::streamsize count = input.gcount();
    if (count > 0 &&
        CC_SHA256_Update(&context, buffer.data(),
                         static_cast<CC_LONG>(count)) == 0) {
      return false;
    }
  }
  return input.eof() && CC_SHA256_Final(digest->data(), &context) != 0;
}

std::string Hex(
    const std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH>& digest) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const std::uint8_t value : digest) {
    output << std::setw(2) << static_cast<unsigned int>(value);
  }
  return output.str();
}

bool CopyFileBytes(const std::filesystem::path& source,
                   std::ofstream* output) {
  std::ifstream input(source, std::ios::binary);
  if (!input) {
    return false;
  }
  std::array<char, 1024 * 1024> buffer{};
  while (input) {
    input.read(buffer.data(), buffer.size());
    const std::streamsize count = input.gcount();
    if (count > 0 && !output->write(buffer.data(), count)) {
      return false;
    }
  }
  return input.eof();
}

void AppendU32(std::vector<std::uint8_t>* bytes, std::uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) {
    bytes->push_back(static_cast<std::uint8_t>(value >> shift));
  }
}

void AppendU64(std::vector<std::uint8_t>* bytes, std::uint64_t value) {
  for (int shift = 0; shift < 64; shift += 8) {
    bytes->push_back(static_cast<std::uint8_t>(value >> shift));
  }
}

bool ReadU32(std::ifstream* input, std::uint32_t* value) {
  std::array<std::uint8_t, 4> bytes{};
  if (!input->read(reinterpret_cast<char*>(bytes.data()), bytes.size())) {
    return false;
  }
  *value = 0;
  for (int shift = 0; shift < 32; shift += 8) {
    *value |= static_cast<std::uint32_t>(bytes[shift / 8]) << shift;
  }
  return true;
}

bool ReadU64(std::ifstream* input, std::uint64_t* value) {
  std::array<std::uint8_t, 8> bytes{};
  if (!input->read(reinterpret_cast<char*>(bytes.data()), bytes.size())) {
    return false;
  }
  *value = 0;
  for (int shift = 0; shift < 64; shift += 8) {
    *value |= static_cast<std::uint64_t>(bytes[shift / 8]) << shift;
  }
  return true;
}

std::vector<std::filesystem::path> RegularFiles(
    const std::filesystem::path& directory) {
  std::vector<std::filesystem::path> files;
  for (const auto& entry : std::filesystem::directory_iterator(directory)) {
    if (entry.is_regular_file()) {
      files.push_back(entry.path());
    }
  }
  std::sort(files.begin(), files.end(), [](const auto& left, const auto& right) {
    return left.filename().generic_string() < right.filename().generic_string();
  });
  return files;
}

bool BuildContainerIndex(std::vector<ContainerEntry>* entries,
                         std::vector<std::uint8_t>* index) {
  index->insert(index->end(), kContainerMagic,
                kContainerMagic + sizeof(kContainerMagic) - 1);
  if (entries->size() > std::numeric_limits<std::uint32_t>::max()) {
    return false;
  }
  AppendU32(index, static_cast<std::uint32_t>(entries->size()));
  std::uint64_t index_size = sizeof(kContainerMagic) - 1 + 4 + 32;
  for (const ContainerEntry& entry : *entries) {
    if (entry.name.size() > std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }
    index_size += 4 + entry.name.size() + 8 + 8 + 8 + entry.raw_sha.size();
  }
  std::uint64_t payload_offset = index_size;
  for (ContainerEntry& entry : *entries) {
    entry.payload_offset = payload_offset;
    payload_offset += entry.compressed_size;
    AppendU32(index, static_cast<std::uint32_t>(entry.name.size()));
    index->insert(index->end(), entry.name.begin(), entry.name.end());
    AppendU64(index, entry.raw_size);
    AppendU64(index, entry.compressed_size);
    AppendU64(index, entry.payload_offset);
    index->insert(index->end(), entry.raw_sha.begin(), entry.raw_sha.end());
  }
  return index->size() + 32 == index_size;
}

bool WriteContainer(const std::filesystem::path& output_path,
                    std::vector<ContainerEntry>* entries) {
  std::vector<std::uint8_t> index;
  if (!BuildContainerIndex(entries, &index)) {
    return false;
  }
  const auto index_sha = Sha256Bytes(index);
  std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
  if (!output ||
      !output.write(reinterpret_cast<const char*>(index.data()), index.size()) ||
      !output.write(reinterpret_cast<const char*>(index_sha.data()),
                    index_sha.size())) {
    return false;
  }
  for (const ContainerEntry& entry : *entries) {
    if (!CopyFileBytes(entry.archive_path, &output)) {
      return false;
    }
  }
  output.close();
  return static_cast<bool>(output);
}

bool ReadContainerIndex(const std::filesystem::path& container,
                        std::vector<ContainerEntry>* entries) {
  std::ifstream input(container, std::ios::binary);
  std::array<char, sizeof(kContainerMagic) - 1> magic{};
  std::uint32_t count = 0;
  if (!input.read(magic.data(), magic.size()) ||
      std::memcmp(magic.data(), kContainerMagic, magic.size()) != 0 ||
      !ReadU32(&input, &count) || count > 100000) {
    return false;
  }
  std::vector<std::uint8_t> index;
  index.insert(index.end(), magic.begin(), magic.end());
  AppendU32(&index, count);
  std::uint64_t previous_end = 0;
  for (std::uint32_t item = 0; item < count; ++item) {
    std::uint32_t name_size = 0;
    if (!ReadU32(&input, &name_size) || name_size == 0 || name_size > 4096) {
      return false;
    }
    AppendU32(&index, name_size);
    ContainerEntry entry;
    entry.name.resize(name_size);
    if (!input.read(entry.name.data(), name_size) ||
        entry.name.find('/') != std::string::npos ||
        !ReadU64(&input, &entry.raw_size) ||
        !ReadU64(&input, &entry.compressed_size) ||
        !ReadU64(&input, &entry.payload_offset) ||
        !input.read(reinterpret_cast<char*>(entry.raw_sha.data()),
                    entry.raw_sha.size())) {
      return false;
    }
    index.insert(index.end(), entry.name.begin(), entry.name.end());
    AppendU64(&index, entry.raw_size);
    AppendU64(&index, entry.compressed_size);
    AppendU64(&index, entry.payload_offset);
    index.insert(index.end(), entry.raw_sha.begin(), entry.raw_sha.end());
    if (item > 0 && entry.payload_offset != previous_end) {
      return false;
    }
    previous_end = entry.payload_offset + entry.compressed_size;
    entries->push_back(std::move(entry));
  }
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> stored_index_sha{};
  if (!input.read(reinterpret_cast<char*>(stored_index_sha.data()),
                  stored_index_sha.size()) ||
      stored_index_sha != Sha256Bytes(index)) {
    return false;
  }
  if (!entries->empty() &&
      entries->front().payload_offset != index.size() + stored_index_sha.size()) {
    return false;
  }
  std::uint64_t container_size = 0;
  return FileSize(container, &container_size) && previous_end == container_size;
}

bool ExtractContainer(const std::filesystem::path& container,
                      const std::filesystem::path& archive_directory,
                      const std::filesystem::path& decoded_directory,
                      std::uint64_t* decoded_bytes) {
  std::vector<ContainerEntry> entries;
  if (!ReadContainerIndex(container, &entries) ||
      !std::filesystem::create_directories(archive_directory) ||
      !std::filesystem::create_directories(decoded_directory)) {
    return false;
  }
  std::ifstream input(container, std::ios::binary);
  *decoded_bytes = 0;
  for (const ContainerEntry& entry : entries) {
    const std::filesystem::path archive = archive_directory / (entry.name + ".zpaq");
    const std::filesystem::path decoded = decoded_directory / entry.name;
    input.clear();
    input.seekg(static_cast<std::streamoff>(entry.payload_offset), std::ios::beg);
    std::ofstream output(archive, std::ios::binary | std::ios::trunc);
    std::uint64_t remaining = entry.compressed_size;
    std::array<char, 1024 * 1024> buffer{};
    while (remaining > 0) {
      const std::size_t count = static_cast<std::size_t>(
          std::min<std::uint64_t>(remaining, buffer.size()));
      if (!input.read(buffer.data(), count) || !output.write(buffer.data(), count)) {
        return false;
      }
      remaining -= count;
    }
    output.close();
    if (!output) {
      return false;
    }
    const int32_t status = pw_zpaq_decompress_file(
        archive.c_str(), decoded.c_str(), pw_zpaq_cancellation_generation());
    std::uint64_t raw_size = 0;
    std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> raw_sha{};
    if (status != PW_ZPAQ_OK || !FileSize(decoded, &raw_size) ||
        !Sha256File(decoded, &raw_sha) || raw_size != entry.raw_size ||
        raw_sha != entry.raw_sha) {
      return false;
    }
    *decoded_bytes += raw_size;
  }
  return true;
}

bool IntegrityOk(const std::filesystem::path& database_path) {
  sqlite3* database = nullptr;
  const std::string uri = "file:" + database_path.string() + "?immutable=1";
  if (sqlite3_open_v2(uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr) !=
      SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }
  sqlite3_stmt* statement = nullptr;
  bool ok = sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1,
                               &statement, nullptr) == SQLITE_OK &&
            sqlite3_step(statement) == SQLITE_ROW;
  if (ok) {
    const char* value = reinterpret_cast<const char*>(
        sqlite3_column_text(statement, 0));
    ok = value != nullptr && std::strcmp(value, "ok") == 0;
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
  return ok;
}

std::vector<DescriptorRequest> RandomReadRequests(
    const std::filesystem::path& source) {
  std::vector<DescriptorRequest> requests;
  sqlite3* database = nullptr;
  if (sqlite3_open_v2(source.c_str(), &database, SQLITE_OPEN_READONLY, nullptr) !=
      SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return requests;
  }
  sqlite3_stmt* total_statement = nullptr;
  std::uint64_t total = 0;
  if (sqlite3_prepare_v2(database, "SELECT coalesce(sum(rows),0) FROM descriptors",
                         -1, &total_statement, nullptr) == SQLITE_OK &&
      sqlite3_step(total_statement) == SQLITE_ROW) {
    total = static_cast<std::uint64_t>(sqlite3_column_int64(total_statement, 0));
  }
  sqlite3_finalize(total_statement);
  if (total == 0) {
    sqlite3_close(database);
    return requests;
  }
  const std::array<std::uint64_t, 3> targets = {0, total / 2, total - 1};
  sqlite3_stmt* statement = nullptr;
  if (sqlite3_prepare_v2(database,
                         "SELECT image_id,rows,cols,data FROM descriptors "
                         "ORDER BY image_id",
                         -1, &statement, nullptr) != SQLITE_OK) {
    sqlite3_close(database);
    return requests;
  }
  std::uint64_t base = 0;
  std::size_t target_index = 0;
  while (target_index < targets.size() && sqlite3_step(statement) == SQLITE_ROW) {
    const std::int64_t image_id = sqlite3_column_int64(statement, 0);
    const std::uint64_t rows =
        static_cast<std::uint64_t>(sqlite3_column_int64(statement, 1));
    const std::int64_t columns = sqlite3_column_int64(statement, 2);
    const auto* data = static_cast<const std::uint8_t*>(
        sqlite3_column_blob(statement, 3));
    const int bytes = sqlite3_column_bytes(statement, 3);
    if (columns != 128 || data == nullptr || bytes < 0 ||
        static_cast<std::uint64_t>(bytes) != rows * 128) {
      requests.clear();
      break;
    }
    while (target_index < targets.size() && targets[target_index] < base + rows) {
      DescriptorRequest request;
      request.image_id = image_id;
      request.row = static_cast<std::int64_t>(targets[target_index] - base);
      std::copy_n(data + request.row * 128, 128, request.expected.begin());
      requests.push_back(request);
      ++target_index;
    }
    base += rows;
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
  return requests;
}

std::uint64_t DirectoryBytes(const std::filesystem::path& directory) {
  std::uint64_t total = 0;
  for (const auto& entry :
       std::filesystem::recursive_directory_iterator(directory)) {
    if (entry.is_regular_file()) {
      total += entry.file_size();
    }
  }
  return total;
}

std::uint64_t PeakRssBytes() {
  struct rusage usage {};
  return getrusage(RUSAGE_SELF, &usage) == 0
             ? static_cast<std::uint64_t>(usage.ru_maxrss)
             : 0;
}

bool WriteDurable(const std::filesystem::path& output_path,
                  const std::string& contents) {
  std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
  if (!output || !output.write(contents.data(), contents.size())) {
    return false;
  }
  output.close();
  if (!output) {
    return false;
  }
  const int descriptor = open(output_path.c_str(), O_RDONLY);
  if (descriptor < 0) {
    return false;
  }
  const bool synced = fsync(descriptor) == 0;
  close(descriptor);
  return synced;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 4) {
    return Fail("usage: pwa2-bench <source.db> <run-directory> <result.json>");
  }
  const std::filesystem::path source = argv[1];
  const std::filesystem::path run_directory = argv[2];
  const std::filesystem::path result_path = argv[3];
  if (std::strcmp(pw_zpaq_version(), "7.15") != 0 ||
      std::strcmp(
          pw_zpaq_revision(),
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") !=
          0) {
    return Fail("unexpected ZPAQ identity");
  }
  if (std::filesystem::exists(run_directory) ||
      !std::filesystem::create_directories(run_directory)) {
    return Fail("run directory must be a new path");
  }
  const auto started = std::chrono::steady_clock::now();
  const std::filesystem::path raw_members = run_directory / "raw_members";
  const std::filesystem::path archives = run_directory / "archives";
  const std::filesystem::path container = run_directory / "pwa2.zpaq";
  const std::filesystem::path extracted_archives =
      run_directory / "extracted_archives";
  const std::filesystem::path decoded_members = run_directory / "decoded_members";
  const std::filesystem::path materialized = run_directory / "materialized.db";

  std::uint64_t source_bytes = 0;
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> source_sha_before{};
  if (!FileSize(source, &source_bytes) ||
      !Sha256File(source, &source_sha_before) || !IntegrityOk(source)) {
    return Fail("source identity or integrity failed");
  }

  pw::pwa2::Options options;
  options.descriptor_block_records = 32768;
  pw::pwa2::Stats stats;
  std::string pwa2_error;
  std::cerr << "PWA2_PACK_START source_bytes=" << source_bytes << std::endl;
  if (pw::pwa2::PackDatabase(source, raw_members, options, &stats, &pwa2_error) !=
      pw::pwa2::Status::kOk) {
    return Fail("PWA2 pack failed: " + pwa2_error);
  }
  std::cerr << "PWA2_PACK_DONE members=" << stats.member_count
            << " raw_member_bytes=" << stats.raw_member_bytes << std::endl;
  if (!std::filesystem::create_directories(archives)) {
    return Fail("cannot create archive directory");
  }

  std::vector<ContainerEntry> entries;
  const std::vector<std::filesystem::path> raw_files = RegularFiles(raw_members);
  for (std::size_t index = 0; index < raw_files.size(); ++index) {
    const std::filesystem::path& raw = raw_files[index];
    ContainerEntry entry;
    entry.name = raw.filename().generic_string();
    entry.archive_path = archives / (entry.name + ".zpaq");
    if (!FileSize(raw, &entry.raw_size) || !Sha256File(raw, &entry.raw_sha)) {
      return Fail("cannot measure raw member: " + entry.name);
    }
    std::cerr << "PWA2_ZPAQ_START member=" << (index + 1) << "/"
              << raw_files.size() << " name=" << entry.name
              << " raw_bytes=" << entry.raw_size << std::endl;
    const int32_t status = pw_zpaq_compress_file(
        raw.c_str(), entry.archive_path.c_str(), 5,
        pw_zpaq_cancellation_generation());
    if (status != PW_ZPAQ_OK ||
        !FileSize(entry.archive_path, &entry.compressed_size)) {
      return Fail(std::string("ZPAQ member compression failed: ") +
                  pw_zpaq_error_message(status) + " " + pw_zpaq_last_error());
    }
    std::cerr << "PWA2_ZPAQ_DONE member=" << (index + 1) << "/"
              << raw_files.size() << " compressed_bytes="
              << entry.compressed_size << std::endl;
    entries.push_back(std::move(entry));
  }
  if (!WriteContainer(container, &entries)) {
    return Fail("cannot write complete PWA2 container");
  }

  std::cerr << "PWA2_VERIFY_START container_members=" << entries.size()
            << std::endl;
  std::uint64_t decoded_bytes = 0;
  if (!ExtractContainer(container, extracted_archives, decoded_members,
                        &decoded_bytes)) {
    return Fail("PWA2 container decode verification failed");
  }
  pw::pwa2::Verification verification;
  if (pw::pwa2::VerifyDatabase(source, decoded_members, &verification,
                               &pwa2_error) != pw::pwa2::Status::kOk) {
    return Fail("PWA2 logical verification failed: " + pwa2_error);
  }
  if (pw::pwa2::MaterializeDatabase(decoded_members, materialized, &pwa2_error) !=
      pw::pwa2::Status::kOk) {
    return Fail("PWA2 materialization failed: " + pwa2_error);
  }
  bool databases_equal = false;
  if (pw::pwa2::CompareDatabasesLogical(source, materialized, &databases_equal,
                                        &pwa2_error) !=
          pw::pwa2::Status::kOk ||
      !databases_equal) {
    return Fail("materialized logical comparison failed: " + pwa2_error);
  }

  bool random_reads_exact = true;
  std::uint64_t random_read_members_touched = 0;
  const std::vector<DescriptorRequest> requests = RandomReadRequests(source);
  if (requests.size() != 3) {
    return Fail("cannot build random-read requests");
  }
  for (const DescriptorRequest& request : requests) {
    std::array<std::uint8_t, 128> actual{};
    std::uint64_t touched = 0;
    if (pw::pwa2::ReadDescriptor(decoded_members, request.image_id, request.row,
                                 &actual, &touched, &pwa2_error) !=
            pw::pwa2::Status::kOk ||
        actual != request.expected || touched == 0 ||
        touched >= stats.member_count) {
      random_reads_exact = false;
      break;
    }
    random_read_members_touched =
        std::max(random_read_members_touched, touched);
  }

  std::uint64_t complete_persisted_bytes = 0;
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> container_sha{};
  std::uint64_t source_bytes_after = 0;
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> source_sha_after{};
  if (!FileSize(container, &complete_persisted_bytes) ||
      !Sha256File(container, &container_sha) ||
      !FileSize(source, &source_bytes_after) ||
      !Sha256File(source, &source_sha_after)) {
    return Fail("final identity measurement failed");
  }
  const bool source_unchanged =
      source_bytes_after == source_bytes && source_sha_after == source_sha_before;
  const bool materialized_sqlite_integrity_ok = IntegrityOk(materialized);
  const bool logical_sha256_equal =
      !verification.source_logical_sha256.empty() &&
      verification.source_logical_sha256 ==
          verification.restored_logical_sha256;
  const bool exact = source_unchanged && logical_sha256_equal &&
                     verification.all_cells_equal &&
                     verification.all_rows_and_order_equal &&
                     random_reads_exact && materialized_sqlite_integrity_ok;
  const bool size_gate_pass =
      exact && complete_persisted_bytes <= kMaximumAcceptedBytes;
  std::cerr << "PWA2_VERIFY_DONE exact=" << (exact ? 1 : 0)
            << " persisted_bytes=" << complete_persisted_bytes
            << " size_gate_pass=" << (size_gate_pass ? 1 : 0) << std::endl;
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started);
  const std::uint64_t peak_temp_bytes = DirectoryBytes(run_directory);

  std::ostringstream result;
  result << "{\"schema\":\"pw_pwa2_structure_zpaq_result_v1\""
         << ",\"source_bytes\":" << source_bytes
         << ",\"source_sha256\":\"" << Hex(source_sha_before) << "\""
         << ",\"baseline_track_delta_bytes\":124401918"
         << ",\"maximum_accepted_bytes\":111961726"
         << ",\"complete_persisted_bytes\":" << complete_persisted_bytes
         << ",\"container_sha256\":\"" << Hex(container_sha) << "\""
         << ",\"raw_member_bytes\":" << stats.raw_member_bytes
         << ",\"decoded_member_bytes\":" << decoded_bytes
         << ",\"member_count\":" << stats.member_count
         << ",\"descriptor_nodes\":" << stats.descriptor_nodes
         << ",\"root_descriptor_nodes\":" << stats.root_descriptor_nodes
         << ",\"predicted_descriptor_nodes\":"
         << stats.predicted_descriptor_nodes
         << ",\"unmatched_descriptor_nodes\":"
         << stats.unmatched_descriptor_nodes
         << ",\"keypoint_records\":" << stats.keypoint_records
         << ",\"match_records\":" << stats.match_records
         << ",\"two_view_records\":" << stats.two_view_records
         << ",\"logical_sha256_equal\":"
         << (logical_sha256_equal ? 1 : 0)
         << ",\"all_cells_equal\":"
         << (verification.all_cells_equal ? 1 : 0)
         << ",\"all_rows_and_order_equal\":"
         << (verification.all_rows_and_order_equal ? 1 : 0)
         << ",\"random_reads_exact\":" << (random_reads_exact ? 1 : 0)
         << ",\"random_read_members_touched\":"
         << random_read_members_touched
         << ",\"materialized_sqlite_integrity_ok\":"
         << (materialized_sqlite_integrity_ok ? 1 : 0)
         << ",\"source_unchanged\":" << (source_unchanged ? 1 : 0)
         << ",\"size_gate_pass\":" << (size_gate_pass ? 1 : 0)
         << ",\"elapsed_ms\":" << elapsed.count()
         << ",\"peak_rss_bytes\":" << PeakRssBytes()
         << ",\"peak_temp_bytes\":" << peak_temp_bytes << "}";
  if (!WriteDurable(result_path, result.str() + "\n")) {
    return Fail("cannot persist result");
  }
  std::cout << result.str() << '\n';
  if (!exact) {
    return Fail("one or more exactness gates failed");
  }
  std::cout << "PW_PWA2_STRUCTURE_ZPAQ_BENCH_OK complete_persisted_bytes="
            << complete_persisted_bytes
            << " size_gate_pass=" << (size_gate_pass ? 1 : 0) << '\n';
  return 0;
}
