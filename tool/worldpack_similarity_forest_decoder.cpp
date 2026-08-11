// Reuse the exact, already verified similarity-forest container and inverse
// implementation from the frozen benchmark without copying its algorithms.
#define main pw_similarity_forest_benchmark_main
#include "sqlite_descriptor_similarity_forest_zpaq_bench.cpp"
#undef main

int main(int argc, char **argv) {
  if (argc != 4) {
    return Fail("usage: decoder <archive.zpaq> <restored.db> <expected-sha256>");
  }
  const std::string archive = argv[1];
  const std::string restored = argv[2];
  const std::string expected_sha256 = argv[3];
  const std::string decoded_container = restored + ".decoded.container";
  const std::string decoded_database = restored + ".decoded.db";
  std::remove(restored.c_str());
  std::remove(decoded_container.c_str());
  std::remove(decoded_database.c_str());
  if (std::strcmp(pw_zpaq_version(), "7.15") != 0 ||
      std::strcmp(
          pw_zpaq_revision(),
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") !=
          0) {
    return Fail("unexpected ZPAQ identity");
  }
  const std::uint64_t generation = pw_zpaq_cancellation_generation();
  const int32_t status = pw_zpaq_decompress_file(
      archive.c_str(), decoded_container.c_str(), generation);
  if (status != PW_ZPAQ_OK) {
    return Fail(std::string("ZPAQ decode failed: ") +
                pw_zpaq_error_message(status) + " " + pw_zpaq_last_error());
  }
  std::vector<std::uint8_t> sidecar;
  std::uint64_t descriptor_nodes = 0;
  if (!ReadContainer(decoded_container, decoded_database, &sidecar,
                     &descriptor_nodes)) {
    return Fail("similarity-forest container is invalid");
  }
  std::string error;
  if (!SimilarityInverse(decoded_database, restored, sidecar, descriptor_nodes,
                         &error)) {
    return Fail("similarity-forest inverse failed: " + error);
  }
  std::uint64_t restored_bytes = 0;
  std::string restored_sha256;
  const bool exact = FileSize(restored, &restored_bytes) &&
                     restored_bytes == 198983680 &&
                     Sha256Hex(restored, &restored_sha256) &&
                     restored_sha256 == expected_sha256 &&
                     IntegrityOk(restored);
  std::remove(decoded_container.c_str());
  std::remove(decoded_database.c_str());
  if (!exact) {
    std::remove(restored.c_str());
    return Fail("restored SQLite exactness or integrity failed");
  }
  std::cout << "{\"schema\":\"pw_worldpack_similarity_decoder_v1\""
            << ",\"restored_bytes\":" << restored_bytes
            << ",\"restored_sha256\":\"" << restored_sha256 << "\""
            << ",\"sqlite_integrity_ok\":1}\n";
  return 0;
}

