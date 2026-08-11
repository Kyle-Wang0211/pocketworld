// Export only the already-selected similarity-forest arm for WorldPack.
// Reuse the frozen benchmark implementation so the transform and inverse do
// not fork into a second algorithm.
#define main pw_similarity_forest_benchmark_main
#include "sqlite_descriptor_similarity_forest_zpaq_bench.cpp"
#undef main

int main(int argc, char **argv) {
  if (argc != 4) {
    return Fail("usage: export <source.db> <run-directory> <result.json>");
  }
  const std::string source = argv[1];
  const std::string run_directory = argv[2];
  const std::string result_path = argv[3];
  constexpr const char *kExpectedSourceSha =
      "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0";
  constexpr std::uint64_t kExpectedArchiveBytes = 116739319;
  constexpr const char *kExpectedArchiveSha =
      "9b425ddb6751398593c0beba8a387a4f69693c8d5dc4737b16911ce3d3f9b3e1";

  if (std::strcmp(pw_zpaq_version(), "7.15") != 0 ||
      std::strcmp(
          pw_zpaq_revision(),
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") !=
          0) {
    return Fail("unexpected ZPAQ identity");
  }
  std::uint64_t source_bytes = 0;
  std::string source_sha;
  if (!FileSize(source, &source_bytes) || source_bytes != 198983680 ||
      !Sha256Hex(source, &source_sha) || source_sha != kExpectedSourceSha ||
      !IntegrityOk(source)) {
    return Fail("immutable source identity or integrity failed");
  }

  ArmResult arm;
  std::string error;
  if (!RunArm("similarity_forest_v1", source, run_directory, source_sha, &arm,
              &error)) {
    return Fail("similarity-forest export: " + error);
  }
  if (arm.archive_bytes != kExpectedArchiveBytes ||
      arm.archive_sha256 != kExpectedArchiveSha) {
    return Fail("exported archive differs from the frozen winning arm");
  }

  std::ofstream output(result_path, std::ios::trunc);
  if (!output) {
    return Fail("could not create export result JSON");
  }
  output << "{\"schema\":\"pw_worldpack_similarity_forest_export_v1\""
         << ",\"source_bytes\":" << source_bytes << ",\"source_sha256\":\""
         << source_sha << "\",\"arm\":";
  AppendArmJson(arm, &output);
  output << ",\"frozen_archive_bytes\":" << kExpectedArchiveBytes
         << ",\"frozen_archive_sha256\":\"" << kExpectedArchiveSha
         << "\",\"byte_equal\":1,\"sha256_equal\":1"
         << ",\"sqlite_integrity_ok\":1,\"production_promoted\":0}\n";
  output.flush();
  if (!output) {
    return Fail("export result JSON write failed");
  }
  std::cout << "PW_WORLDPACK_SIMILARITY_EXPORT_COMPLETE result=" << result_path
            << '\n';
  return 0;
}

