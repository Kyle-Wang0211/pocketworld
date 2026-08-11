#include "pwa2_sqlite_logical_archive.h"
#include "descriptor_similarity_forest.h"

#include <cstdint>
#include <filesystem>
#include <iostream>
#include <string>

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: pwa2-pack-only <source.db> <member-directory>\n";
    return 2;
  }
  const std::filesystem::path source = argv[1];
  const std::filesystem::path destination = argv[2];
  if (std::filesystem::exists(destination)) {
    std::cerr << "destination already exists\n";
    return 3;
  }
  pw::pwa2::Options options;
  options.descriptor_block_records = 32768;
  pw::similarity_forest::Stats forest_stats;
  options.descriptor_parent_builder =
      [&forest_stats](const std::vector<std::uint8_t>& descriptors,
                      std::vector<std::uint64_t>* parents,
                      std::string* error) {
        pw::similarity_forest::Options forest_options;
        return pw::similarity_forest::Build(descriptors, forest_options,
                                            parents, &forest_stats, error);
      };
  pw::pwa2::Stats stats;
  std::string error;
  const pw::pwa2::Status status = pw::pwa2::PackDatabase(
      source.string(), destination.string(), options, &stats, &error);
  if (status != pw::pwa2::Status::kOk) {
    std::cerr << "PWA2 pack failed: " << error << '\n';
    return 4;
  }
  std::cout << "{\"schema\":\"pw_pwa2_pack_only_v1\""
            << ",\"table_count\":" << stats.table_count
            << ",\"row_count\":" << stats.row_count
            << ",\"member_count\":" << stats.member_count
            << ",\"descriptor_nodes\":" << stats.descriptor_nodes
            << ",\"root_descriptor_nodes\":"
            << stats.root_descriptor_nodes
            << ",\"predicted_descriptor_nodes\":"
            << stats.predicted_descriptor_nodes
            << ",\"unmatched_descriptor_nodes\":"
            << stats.unmatched_descriptor_nodes
            << ",\"forest_training_nodes\":"
            << forest_stats.training_nodes
            << ",\"keypoint_records\":" << stats.keypoint_records
            << ",\"match_records\":" << stats.match_records
            << ",\"two_view_records\":" << stats.two_view_records
            << ",\"raw_member_bytes\":" << stats.raw_member_bytes << "}\n";
  return 0;
}
