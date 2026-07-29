#include "../Runner/pw_zpaq_bridge.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <unistd.h>

namespace {

constexpr size_t kSourceSize = 1024 * 1024;

bool WriteBytes(const std::string& path, const std::vector<unsigned char>& bytes) {
  FILE* file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) {
    return false;
  }
  const bool wrote_all =
      std::fwrite(bytes.data(), 1, bytes.size(), file) == bytes.size();
  const bool closed = std::fclose(file) == 0;
  return wrote_all && closed;
}

bool ReadBytes(const std::string& path, std::vector<unsigned char>* bytes) {
  FILE* file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) {
    return false;
  }
  if (std::fseek(file, 0, SEEK_END) != 0) {
    std::fclose(file);
    return false;
  }
  const long size = std::ftell(file);
  if (size < 0 || std::fseek(file, 0, SEEK_SET) != 0) {
    std::fclose(file);
    return false;
  }
  bytes->resize(static_cast<size_t>(size));
  const bool read_all =
      bytes->empty() ||
      std::fread(bytes->data(), 1, bytes->size(), file) == bytes->size();
  const bool closed = std::fclose(file) == 0;
  return read_all && closed;
}

int Fail(const char* message) {
  std::fprintf(stderr, "PW_ZPAQ_SMOKE_FAILED: %s\n", message);
  return 1;
}

}  // namespace

int main() {
  if (std::strcmp(pw_zpaq_version(), "7.15") != 0) {
    return Fail("unexpected ZPAQ version");
  }
  if (std::strcmp(
          pw_zpaq_revision(),
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") !=
      0) {
    return Fail("unexpected ZPAQ revision");
  }

  char directory_template[] = "/private/tmp/pw-zpaq-smoke-XXXXXX";
  const char* directory = mkdtemp(directory_template);
  if (directory == nullptr) {
    return Fail("mkdtemp failed");
  }
  const std::string prefix = std::string(directory) + "/official_sfm_live.db";
  const std::string source_path = prefix;
  const std::string archive_path = prefix + ".zpaq";
  const std::string restored_path = prefix + ".restored";
  const std::string cancelled_path = prefix + ".cancelled";

  std::vector<unsigned char> source(kSourceSize);
  for (size_t index = 0; index < source.size(); ++index) {
    source[index] = static_cast<unsigned char>((index / 4096) % 7);
  }
  if (!WriteBytes(source_path, source)) {
    return Fail("source write failed");
  }

  const uint64_t stale_generation = pw_zpaq_cancellation_generation();
  pw_zpaq_request_cancel();
  int32_t status = pw_zpaq_compress_file(
      source_path.c_str(), cancelled_path.c_str(), 5, stale_generation);
  if (status != PW_ZPAQ_CANCELLED) {
    return Fail("stale cancellation generation was accepted");
  }

  uint64_t generation = pw_zpaq_cancellation_generation();
  status = pw_zpaq_compress_file(
      source_path.c_str(), archive_path.c_str(), 5, generation);
  if (status != PW_ZPAQ_OK) {
    std::fprintf(stderr, "%s: %s\n", pw_zpaq_error_message(status),
                 pw_zpaq_last_error());
    return Fail("method 5 compression failed");
  }

  generation = pw_zpaq_cancellation_generation();
  status = pw_zpaq_decompress_file(
      archive_path.c_str(), restored_path.c_str(), generation);
  if (status != PW_ZPAQ_OK) {
    std::fprintf(stderr, "%s: %s\n", pw_zpaq_error_message(status),
                 pw_zpaq_last_error());
    return Fail("decompression failed");
  }

  std::vector<unsigned char> archive;
  std::vector<unsigned char> restored;
  if (!ReadBytes(archive_path, &archive) ||
      !ReadBytes(restored_path, &restored)) {
    return Fail("output read failed");
  }
  if (restored != source) {
    return Fail("restored bytes differ from source");
  }
  if (archive.size() >= source.size()) {
    return Fail("archive is not smaller than source");
  }

  std::remove(source_path.c_str());
  std::remove(archive_path.c_str());
  std::remove(restored_path.c_str());
  std::remove(cancelled_path.c_str());
  rmdir(directory);

  std::printf(
      "PW_ZPAQ_SMOKE_OK source=%zu archive=%zu saved=%.4f%% byte_equal=1\n",
      source.size(), archive.size(),
      100.0 * (1.0 - static_cast<double>(archive.size()) / source.size()));
  return 0;
}
