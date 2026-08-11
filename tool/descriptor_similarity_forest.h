#ifndef PW_DESCRIPTOR_SIMILARITY_FOREST_H_
#define PW_DESCRIPTOR_SIMILARITY_FOREST_H_

#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace pw::similarity_forest {

constexpr std::uint64_t kNoParent = std::numeric_limits<std::uint64_t>::max();

struct Options {
  std::size_t dimension = 128;
  std::size_t block_descriptors = 8192;
  std::size_t nlist = 2048;
  std::size_t nprobe = 32;
  std::size_t maximum_training_descriptors = 131072;
  std::size_t nearest_candidates = 1;
  int seed = 20260802;
};

struct Stats {
  std::uint64_t descriptor_nodes = 0;
  std::uint64_t root_nodes = 0;
  std::uint64_t predicted_nodes = 0;
  std::uint64_t training_nodes = 0;
};

bool ValidateParents(const std::vector<std::uint64_t> &parents,
                     std::string *error);

bool EncodeParents(const std::vector<std::uint64_t> &parents,
                   std::vector<std::uint8_t> *encoded, std::string *error);

bool DecodeParents(const std::vector<std::uint8_t> &encoded,
                   std::size_t expected_nodes,
                   std::vector<std::uint64_t> *parents, std::string *error);

bool TransformResiduals(std::vector<std::uint8_t> *descriptors,
                        std::size_t dimension,
                        const std::vector<std::uint64_t> &parents, bool inverse,
                        std::string *error);

// Uses exact incremental IndexFlatL2 when options.nlist == 0. Otherwise it
// trains an encoder-only IndexIVFFlat and adds descriptor blocks only after
// querying them, so every selected parent is strictly earlier than its child.
bool Build(const std::vector<std::uint8_t> &descriptors, const Options &options,
           std::vector<std::uint64_t> *parents, Stats *stats,
           std::string *error);

} // namespace pw::similarity_forest

#endif // PW_DESCRIPTOR_SIMILARITY_FOREST_H_
