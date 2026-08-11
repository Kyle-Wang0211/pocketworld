#include "descriptor_similarity_forest.h"

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

int Fail(const std::string &message) {
  std::cerr << "PW_DESCRIPTOR_SIMILARITY_FOREST_TEST_FAILED: " << message
            << '\n';
  return 1;
}

} // namespace

int main() {
  constexpr std::size_t kDimension = 4;
  const std::vector<std::uint8_t> original = {
      1, 2, 3, 4, 2, 4, 6, 8, 255, 0, 128, 64, 254, 2, 127, 65, 3, 6, 9, 12,
  };
  const std::vector<std::uint64_t> parents = {
      pw::similarity_forest::kNoParent,
      0,
      pw::similarity_forest::kNoParent,
      2,
      1,
  };

  std::string error;
  if (!pw::similarity_forest::ValidateParents(parents, &error)) {
    return Fail("valid DAG rejected: " + error);
  }
  std::vector<std::uint64_t> invalid = parents;
  invalid[3] = 4;
  if (pw::similarity_forest::ValidateParents(invalid, &error)) {
    return Fail("forward parent was accepted");
  }

  std::vector<std::uint8_t> encoded_sidecar;
  if (!pw::similarity_forest::EncodeParents(parents, &encoded_sidecar,
                                            &error)) {
    return Fail("sidecar encode failed: " + error);
  }
  std::vector<std::uint64_t> decoded_parents;
  if (!pw::similarity_forest::DecodeParents(encoded_sidecar, parents.size(),
                                            &decoded_parents, &error) ||
      decoded_parents != parents) {
    return Fail("sidecar round-trip failed: " + error);
  }
  std::vector<std::uint8_t> truncated = encoded_sidecar;
  truncated.pop_back();
  if (pw::similarity_forest::DecodeParents(truncated, parents.size(),
                                           &decoded_parents, &error)) {
    return Fail("truncated sidecar was accepted");
  }

  std::vector<std::uint8_t> residuals = original;
  if (!pw::similarity_forest::TransformResiduals(&residuals, kDimension,
                                                 parents, false, &error) ||
      residuals == original) {
    return Fail("forward residual transform failed: " + error);
  }
  if (!pw::similarity_forest::TransformResiduals(&residuals, kDimension,
                                                 parents, true, &error) ||
      residuals != original) {
    return Fail("inverse residual transform was not exact: " + error);
  }

  pw::similarity_forest::Options options;
  options.dimension = kDimension;
  options.block_descriptors = 2;
  options.nlist = 0;
  options.nearest_candidates = 1;
  std::vector<std::uint64_t> built_parents;
  pw::similarity_forest::Stats stats;
  if (!pw::similarity_forest::Build(original, options, &built_parents, &stats,
                                    &error)) {
    return Fail("small exact forest build failed: " + error);
  }
  if (!pw::similarity_forest::ValidateParents(built_parents, &error) ||
      built_parents.size() != original.size() / kDimension ||
      stats.root_nodes != 2 || stats.predicted_nodes != 3) {
    return Fail("small exact forest coverage is wrong: " + error);
  }

  std::cout << "PW_DESCRIPTOR_SIMILARITY_FOREST_TEST_OK\n";
  return 0;
}
