#include "descriptor_similarity_forest.h"

#include <faiss/IndexFlat.h>
#include <faiss/IndexIVFFlat.h>

#include <algorithm>
#include <cmath>
#include <exception>
#include <memory>
#include <sstream>
#include <utility>

namespace pw::similarity_forest {
namespace {

bool Fail(const std::string &message, std::string *error) {
  if (error != nullptr) {
    *error = message;
  }
  return false;
}

void AppendVarint(std::uint64_t value, std::vector<std::uint8_t> *output) {
  while (value >= 0x80u) {
    output->push_back(static_cast<std::uint8_t>((value & 0x7fu) | 0x80u));
    value >>= 7u;
  }
  output->push_back(static_cast<std::uint8_t>(value));
}

bool ReadVarint(const std::vector<std::uint8_t> &input, std::size_t *cursor,
                std::uint64_t *value) {
  std::uint64_t result = 0;
  for (unsigned int byte_index = 0; byte_index < 10; ++byte_index) {
    if (*cursor >= input.size()) {
      return false;
    }
    const std::uint8_t byte = input[(*cursor)++];
    if (byte_index == 9 && (byte & 0xfeu) != 0) {
      return false;
    }
    result |= static_cast<std::uint64_t>(byte & 0x7fu) << (byte_index * 7u);
    if ((byte & 0x80u) == 0) {
      *value = result;
      return true;
    }
  }
  return false;
}

void ConvertBlock(const std::vector<std::uint8_t> &descriptors,
                  std::size_t dimension, std::size_t begin, std::size_t count,
                  std::vector<float> *output) {
  output->resize(count * dimension);
  const std::size_t byte_begin = begin * dimension;
  for (std::size_t index = 0; index < output->size(); ++index) {
    (*output)[index] = static_cast<float>(descriptors[byte_begin + index]);
  }
}

} // namespace

bool ValidateParents(const std::vector<std::uint64_t> &parents,
                     std::string *error) {
  for (std::size_t child = 0; child < parents.size(); ++child) {
    const std::uint64_t parent = parents[child];
    if (parent != kNoParent && parent >= child) {
      std::ostringstream message;
      message << "parent " << parent << " is not earlier than child " << child;
      return Fail(message.str(), error);
    }
  }
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

bool EncodeParents(const std::vector<std::uint64_t> &parents,
                   std::vector<std::uint8_t> *encoded, std::string *error) {
  if (encoded == nullptr) {
    return Fail("encoded parent output is null", error);
  }
  if (!ValidateParents(parents, error)) {
    return false;
  }
  encoded->clear();
  encoded->reserve(parents.size() * 2);
  for (std::size_t child = 0; child < parents.size(); ++child) {
    const std::uint64_t parent = parents[child];
    AppendVarint(parent == kNoParent ? 0 : child - parent, encoded);
  }
  return true;
}

bool DecodeParents(const std::vector<std::uint8_t> &encoded,
                   const std::size_t expected_nodes,
                   std::vector<std::uint64_t> *parents, std::string *error) {
  if (parents == nullptr) {
    return Fail("decoded parent output is null", error);
  }
  parents->assign(expected_nodes, kNoParent);
  std::size_t cursor = 0;
  for (std::size_t child = 0; child < expected_nodes; ++child) {
    std::uint64_t backward_distance = 0;
    if (!ReadVarint(encoded, &cursor, &backward_distance)) {
      return Fail("parent sidecar is truncated or has an invalid varint",
                  error);
    }
    if (backward_distance == 0) {
      continue;
    }
    if (backward_distance > child) {
      return Fail("parent backward distance exceeds child ordinal", error);
    }
    (*parents)[child] = child - backward_distance;
  }
  if (cursor != encoded.size()) {
    return Fail("parent sidecar has trailing bytes", error);
  }
  return ValidateParents(*parents, error);
}

bool TransformResiduals(std::vector<std::uint8_t> *descriptors,
                        const std::size_t dimension,
                        const std::vector<std::uint64_t> &parents,
                        const bool inverse, std::string *error) {
  if (descriptors == nullptr || dimension == 0 ||
      descriptors->size() % dimension != 0 ||
      descriptors->size() / dimension != parents.size()) {
    return Fail("descriptor dimensions do not match parent count", error);
  }
  if (!ValidateParents(parents, error)) {
    return false;
  }

  const std::size_t node_count = parents.size();
  if (inverse) {
    for (std::size_t child = 0; child < node_count; ++child) {
      const std::uint64_t parent = parents[child];
      if (parent == kNoParent) {
        continue;
      }
      const std::size_t child_offset = child * dimension;
      const std::size_t parent_offset =
          static_cast<std::size_t>(parent) * dimension;
      for (std::size_t lane = 0; lane < dimension; ++lane) {
        (*descriptors)[child_offset + lane] =
            static_cast<std::uint8_t>((*descriptors)[child_offset + lane] +
                                      (*descriptors)[parent_offset + lane]);
      }
    }
  } else {
    for (std::size_t child = node_count; child-- > 0;) {
      const std::uint64_t parent = parents[child];
      if (parent == kNoParent) {
        continue;
      }
      const std::size_t child_offset = child * dimension;
      const std::size_t parent_offset =
          static_cast<std::size_t>(parent) * dimension;
      for (std::size_t lane = 0; lane < dimension; ++lane) {
        (*descriptors)[child_offset + lane] =
            static_cast<std::uint8_t>((*descriptors)[child_offset + lane] -
                                      (*descriptors)[parent_offset + lane]);
      }
    }
  }
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

bool Build(const std::vector<std::uint8_t> &descriptors, const Options &options,
           std::vector<std::uint64_t> *parents, Stats *stats,
           std::string *error) {
  if (parents == nullptr || stats == nullptr) {
    return Fail("forest output is null", error);
  }
  if (options.dimension == 0 || options.block_descriptors == 0 ||
      options.nearest_candidates == 0 ||
      descriptors.size() % options.dimension != 0) {
    return Fail("forest options or descriptor dimensions are invalid", error);
  }
  const std::size_t node_count = descriptors.size() / options.dimension;
  parents->assign(node_count, kNoParent);
  *stats = {};
  stats->descriptor_nodes = node_count;
  if (node_count == 0) {
    return true;
  }

  try {
    std::unique_ptr<faiss::IndexFlatL2> quantizer;
    std::unique_ptr<faiss::IndexIVFFlat> ivf;
    std::unique_ptr<faiss::IndexFlatL2> flat;
    faiss::Index *index = nullptr;

    if (options.nlist == 0) {
      flat = std::make_unique<faiss::IndexFlatL2>(options.dimension);
      index = flat.get();
    } else {
      if (options.nlist > node_count || options.nprobe == 0 ||
          options.maximum_training_descriptors < options.nlist) {
        return Fail("IVF parameters are incompatible with descriptor count",
                    error);
      }
      quantizer = std::make_unique<faiss::IndexFlatL2>(options.dimension);
      ivf = std::make_unique<faiss::IndexIVFFlat>(
          quantizer.get(), options.dimension, options.nlist, faiss::METRIC_L2);
      ivf->cp.seed = options.seed;
      ivf->nprobe = std::min(options.nprobe, options.nlist);

      const std::size_t training_count =
          std::min(node_count, options.maximum_training_descriptors);
      std::vector<float> training(training_count * options.dimension);
      for (std::size_t sample = 0; sample < training_count; ++sample) {
        const std::size_t node =
            training_count == 1
                ? 0
                : (sample * (node_count - 1)) / (training_count - 1);
        const std::size_t source_offset = node * options.dimension;
        const std::size_t target_offset = sample * options.dimension;
        for (std::size_t lane = 0; lane < options.dimension; ++lane) {
          training[target_offset + lane] =
              static_cast<float>(descriptors[source_offset + lane]);
        }
      }
      ivf->train(static_cast<faiss::idx_t>(training_count), training.data());
      stats->training_nodes = training_count;
      index = ivf.get();
    }

    const std::size_t first_count =
        std::min(node_count, options.block_descriptors);
    std::vector<float> block;
    ConvertBlock(descriptors, options.dimension, 0, first_count, &block);
    index->add(static_cast<faiss::idx_t>(first_count), block.data());
    stats->root_nodes = first_count;

    for (std::size_t begin = first_count; begin < node_count;
         begin += options.block_descriptors) {
      const std::size_t count =
          std::min(options.block_descriptors, node_count - begin);
      ConvertBlock(descriptors, options.dimension, begin, count, &block);
      std::vector<float> distances(count * options.nearest_candidates);
      std::vector<faiss::idx_t> labels(count * options.nearest_candidates);
      index->search(static_cast<faiss::idx_t>(count), block.data(),
                    static_cast<faiss::idx_t>(options.nearest_candidates),
                    distances.data(), labels.data());
      for (std::size_t row = 0; row < count; ++row) {
        const faiss::idx_t candidate = labels[row * options.nearest_candidates];
        if (candidate < 0 || static_cast<std::uint64_t>(candidate) >= begin) {
          return Fail("Faiss did not return a valid earlier parent", error);
        }
        (*parents)[begin + row] = static_cast<std::uint64_t>(candidate);
        ++stats->predicted_nodes;
      }
      index->add(static_cast<faiss::idx_t>(count), block.data());
    }
  } catch (const std::exception &exception) {
    return Fail(std::string("Faiss forest construction failed: ") +
                    exception.what(),
                error);
  }

  if (!ValidateParents(*parents, error)) {
    return false;
  }
  if (stats->root_nodes + stats->predicted_nodes != node_count) {
    return Fail("forest coverage does not equal descriptor count", error);
  }
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

} // namespace pw::similarity_forest
