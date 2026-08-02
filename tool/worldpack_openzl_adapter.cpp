#include "worldpack_openzl_adapter.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "openzl/codecs/zl_ace.h"
#include "openzl/codecs/zl_clustering.h"
#include "openzl/codecs/zl_conversion.h"
#include "openzl/cpp/CCtx.hpp"
#include "openzl/cpp/Compressor.hpp"
#include "openzl/cpp/DCtx.hpp"
#include "openzl/zl_compressor.h"
#include "openzl/zl_graph_api.h"
#include "tools/training/train.h"
#include "tools/training/train_params.h"
#include "tools/training/utils/utils.h"

namespace {

using Mode = pw::worldpack::openzl::Mode;

constexpr char kVersion[] = "0.2.0";
constexpr char kRevision[] =
    "3dceb64867840201fb8f57a29d179995f700c9b8";
constexpr unsigned kNumBytesTag = 100;
constexpr unsigned kElementWidthTag = 101;
constexpr unsigned kInputTag = 102;

enum class Routing {
  kGeneric,
  kDistinctAce,
  kClustering,
};

std::uint32_t ReadLittleEndian32(const std::uint8_t* data) {
  return static_cast<std::uint32_t>(data[0]) |
         (static_cast<std::uint32_t>(data[1]) << 8) |
         (static_cast<std::uint32_t>(data[2]) << 16) |
         (static_cast<std::uint32_t>(data[3]) << 24);
}

std::string ReadFile(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("could not open input: " + path);
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void WriteFile(const std::string& path, const std::string& contents) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output) {
    throw std::runtime_error("could not open output: " + path);
  }
  output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
  if (!output.good()) {
    throw std::runtime_error("could not write output: " + path);
  }
}

template <Routing routing>
ZL_Report TypedParsingGraph(ZL_Graph* graph,
                            ZL_Edge* input_edges[],
                            const size_t num_inputs) noexcept {
  ZL_RESULT_DECLARE_SCOPE_REPORT(graph);
  assert(num_inputs == 1);
  const ZL_Input* const input = ZL_Edge_getData(input_edges[0]);
  const auto* const input_data =
      static_cast<const std::uint8_t*>(ZL_Input_ptr(input));
  const size_t input_size = ZL_Input_numElts(input);

  std::vector<unsigned> dispatch_indices;
  std::vector<size_t> sizes;
  std::vector<std::uint8_t> element_widths;
  std::unordered_map<std::uint32_t, std::uint32_t> tag_to_dispatch;
  std::unordered_map<std::uint32_t, std::uint32_t> dispatch_to_tag;
  std::uint32_t current_dispatch = 0;
  const auto add_tag = [&](const std::uint32_t tag) {
    dispatch_to_tag[current_dispatch] = tag;
    tag_to_dispatch[tag] = current_dispatch++;
  };
  add_tag(kNumBytesTag);
  add_tag(kElementWidthTag);
  add_tag(kInputTag);

  for (size_t input_position = 0; input_position < input_size;) {
    ZL_ERR_IF_LT(input_size - input_position, 9, srcSize_tooSmall);
    const std::uint32_t num_bytes =
        ReadLittleEndian32(input_data + input_position);
    const std::uint8_t element_width = input_data[input_position + 4];
    const std::uint32_t input_tag =
        ReadLittleEndian32(input_data + input_position + 5);
    if (tag_to_dispatch.count(input_tag) == 0) {
      add_tag(input_tag);
    }
    element_widths.push_back(element_width);
    ZL_ERR_IF_NE(num_bytes % element_width, 0, corruption);
    input_position += 9;
    ZL_ERR_IF_LT(input_size - input_position, num_bytes, srcSize_tooSmall);
    input_position += num_bytes;

    dispatch_indices.push_back(tag_to_dispatch[kNumBytesTag]);
    sizes.push_back(4);
    dispatch_indices.push_back(tag_to_dispatch[kElementWidthTag]);
    sizes.push_back(1);
    dispatch_indices.push_back(tag_to_dispatch[kInputTag]);
    sizes.push_back(4);
    dispatch_indices.push_back(tag_to_dispatch[input_tag]);
    sizes.push_back(num_bytes);
  }

  const ZL_DispatchInstructions instructions = {
      .segmentSizes = sizes.data(),
      .tags = dispatch_indices.data(),
      .nbSegments = sizes.size(),
      .nbTags = current_dispatch,
  };
  ZL_TRY_LET(ZL_EdgeList, dispatched,
             ZL_Edge_runDispatchNode(input_edges[0], &instructions));
  assert(dispatched.nbEdges == 2 + current_dispatch);
  ZL_ERR_IF_ERR(
      ZL_Edge_setDestination(dispatched.edges[0], ZL_GRAPH_COMPRESS_GENERIC));
  ZL_ERR_IF_ERR(
      ZL_Edge_setDestination(dispatched.edges[1], ZL_GRAPH_COMPRESS_GENERIC));
  dispatched.edges += 2;

  std::vector<ZL_Edge*> routed_edges;
  routed_edges.reserve(dispatched.nbEdges - 2);
  for (size_t index = 0; index < 3; ++index) {
    ZL_ERR_IF_ERR(ZL_Edge_setIntMetadata(
        dispatched.edges[index], ZL_CLUSTERING_TAG_METADATA_ID,
        static_cast<int>(dispatch_to_tag[index])));
    routed_edges.push_back(dispatched.edges[index]);
  }
  assert(element_widths.size() == dispatched.nbEdges - 5);
  for (size_t index = 0; index < element_widths.size(); ++index) {
    const ZL_NodeID node = ZL_Node_interpretAsLE(element_widths[index] * 8);
    const size_t dispatch_index = index + 3;
    ZL_TRY_LET_CONST(
        ZL_EdgeList, converted,
        ZL_Edge_runNode(dispatched.edges[dispatch_index], node));
    assert(converted.nbEdges == 1);
    ZL_ERR_IF_ERR(ZL_Edge_setIntMetadata(
        converted.edges[0], ZL_CLUSTERING_TAG_METADATA_ID,
        static_cast<int>(dispatch_to_tag[dispatch_index])));
    routed_edges.push_back(converted.edges[0]);
  }

  if constexpr (routing == Routing::kGeneric) {
    for (ZL_Edge* edge : routed_edges) {
      ZL_ERR_IF_ERR(ZL_Edge_setDestination(edge, ZL_GRAPH_COMPRESS_GENERIC));
    }
  } else if constexpr (routing == Routing::kDistinctAce) {
    const ZL_GraphIDList custom_graphs = ZL_Graph_getCustomGraphs(graph);
    ZL_ERR_IF_NE(custom_graphs.nbGraphIDs, element_widths.size(),
                 graphParameter_invalid);
    for (size_t index = 0; index < 3; ++index) {
      ZL_ERR_IF_ERR(ZL_Edge_setDestination(routed_edges[index],
                                           ZL_GRAPH_COMPRESS_GENERIC));
    }
    for (size_t index = 0; index < element_widths.size(); ++index) {
      ZL_ERR_IF_ERR(ZL_Edge_setDestination(routed_edges[index + 3],
                                           custom_graphs.graphids[index]));
    }
  } else {
    const ZL_GraphIDList custom_graphs = ZL_Graph_getCustomGraphs(graph);
    ZL_ERR_IF_NE(custom_graphs.nbGraphIDs, 1, graphParameter_invalid);
    ZL_ERR_IF_ERR(ZL_Edge_setParameterizedDestination(
        routed_edges.data(), routed_edges.size(), custom_graphs.graphids[0],
        nullptr));
  }
  return ZL_returnSuccess();
}

ZL_GraphID RegisterParser(openzl::Compressor& compressor,
                          const Routing routing,
                          std::vector<ZL_GraphID> custom_graphs) {
  const char* lookup_name = nullptr;
  const char* registered_name = nullptr;
  ZL_FunctionGraphFn callback = nullptr;
  switch (routing) {
    case Routing::kGeneric:
      lookup_name = "PW Typed Parser Generic";
      registered_name = "!PW Typed Parser Generic";
      callback = TypedParsingGraph<Routing::kGeneric>;
      break;
    case Routing::kDistinctAce:
      lookup_name = "PW Typed Parser ACE";
      registered_name = "!PW Typed Parser ACE";
      callback = TypedParsingGraph<Routing::kDistinctAce>;
      break;
    case Routing::kClustering:
      lookup_name = "PW Typed Parser Clustering";
      registered_name = "!PW Typed Parser Clustering";
      callback = TypedParsingGraph<Routing::kClustering>;
      break;
  }
  auto parser = compressor.getGraph(lookup_name);
  if (!parser) {
    ZL_Type input_type = ZL_Type_serial;
    const ZL_FunctionGraphDesc description = {
        .name = registered_name,
        .graph_f = callback,
        .inputTypeMasks = &input_type,
        .nbInputs = 1,
        .customGraphs = nullptr,
        .nbCustomGraphs = 0,
        .localParams = {},
    };
    parser = compressor.registerFunctionGraph(description);
  }
  if (custom_graphs.empty()) {
    return parser.value();
  }
  openzl::GraphParameters parameters = {
      .customGraphs = std::move(custom_graphs),
  };
  return compressor.parameterizeGraph(parser.value(), parameters);
}

ZL_GraphID RegisterStartingGraph(openzl::Compressor& compressor,
                                 const Mode mode,
                                 const std::size_t typed_data_streams) {
  if (mode == Mode::kUntrainedParser) {
    return RegisterParser(compressor, Routing::kGeneric, {});
  }
  if (mode == Mode::kAceComplete) {
    std::vector<ZL_GraphID> ace_graphs;
    ace_graphs.reserve(typed_data_streams);
    for (std::size_t index = 0; index < typed_data_streams; ++index) {
      ace_graphs.push_back(ZL_Compressor_buildACEGraph(compressor.get()));
    }
    return RegisterParser(compressor, Routing::kDistinctAce,
                          std::move(ace_graphs));
  }

  ZL_ClusteringConfig default_config = {
      .clusters = nullptr,
      .nbClusters = 0,
      .typeDefaults = nullptr,
      .nbTypeDefaults = 0,
  };
  std::vector<ZL_GraphID> successors = {
      ZL_GRAPH_STORE,
      ZL_GRAPH_ZSTD,
      ZL_GRAPH_COMPRESS_GENERIC,
      ZL_Compressor_registerStaticGraph_fromNode1o(
          compressor.get(), ZL_NODE_DELTA_INT, ZL_GRAPH_FIELD_LZ),
  };
  const ZL_GraphID clustering = ZL_Clustering_registerGraph(
      compressor.get(), &default_config, successors.data(), successors.size());
  return RegisterParser(compressor, Routing::kClustering, {clustering});
}

std::unique_ptr<openzl::Compressor> CreateFromSerialized(
    const Mode mode,
    const std::size_t typed_data_streams,
    const openzl::poly::string_view serialized) {
  auto compressor = std::make_unique<openzl::Compressor>();
  RegisterStartingGraph(*compressor, mode, typed_data_streams);
  compressor->deserialize(serialized);
  return compressor;
}

std::vector<openzl::training::MultiInput> BuildTrainingInputs(
    const std::vector<std::string>& training_data) {
  std::vector<openzl::training::MultiInput> inputs;
  inputs.reserve(training_data.size());
  for (const std::string& data : training_data) {
    openzl::training::MultiInput input;
    input.add(openzl::Input::refSerial(data));
    inputs.push_back(std::move(input));
  }
  return inputs;
}

}  // namespace

namespace pw::worldpack::openzl {

const char* Version() { return kVersion; }

const char* Revision() { return kRevision; }

const char* ModeName(const Mode mode) {
  switch (mode) {
    case Mode::kUntrainedParser:
      return "untrained_parser";
    case Mode::kAceComplete:
      return "ace_complete";
    case Mode::kClusteringPlusAceComplete:
      return "clustering_plus_ace_complete";
  }
  return "unknown";
}

bool ParseMode(const std::string& value, Mode* mode) {
  if (mode == nullptr) {
    return false;
  }
  if (value == "untrained_parser") {
    *mode = Mode::kUntrainedParser;
    return true;
  }
  if (value == "ace_complete") {
    *mode = Mode::kAceComplete;
    return true;
  }
  if (value == "clustering_plus_ace_complete") {
    *mode = Mode::kClusteringPlusAceComplete;
    return true;
  }
  return false;
}

bool ValidateTypedBundle(const std::string& bundle,
                         std::size_t* typed_data_streams,
                         std::string* error) {
  if (typed_data_streams == nullptr || error == nullptr) {
    return false;
  }
  *typed_data_streams = 0;
  error->clear();
  std::unordered_set<std::uint32_t> tags;
  std::size_t position = 0;
  while (position < bundle.size()) {
    if (bundle.size() - position < 9) {
      *error = "typed bundle header is truncated";
      return false;
    }
    const auto* header = reinterpret_cast<const std::uint8_t*>(
        bundle.data() + static_cast<std::ptrdiff_t>(position));
    const std::uint32_t num_bytes = ReadLittleEndian32(header);
    const std::uint8_t element_width = header[4];
    const std::uint32_t tag = ReadLittleEndian32(header + 5);
    if (element_width != 1 && element_width != 2 && element_width != 4 &&
        element_width != 8) {
      *error = "typed bundle element width is unsupported";
      return false;
    }
    if (num_bytes % element_width != 0) {
      *error = "typed bundle payload is not element aligned";
      return false;
    }
    if (!tags.insert(tag).second) {
      *error = "typed bundle tags must be unique within each chunk";
      return false;
    }
    position += 9;
    if (num_bytes > bundle.size() - position) {
      *error = "typed bundle payload is truncated";
      return false;
    }
    position += num_bytes;
  }
  if (tags.empty()) {
    *error = "typed bundle must contain at least one stream";
    return false;
  }
  *typed_data_streams = tags.size();
  return true;
}

bool Run(const Config& config, Result* result, std::string* error) {
  if (result == nullptr || error == nullptr || config.test_path.empty() ||
      config.frame_path.empty() || config.encoder_model_path.empty() ||
      config.restored_path.empty() || config.training_threads == 0) {
    return false;
  }
  *result = {};
  error->clear();
  try {
    const std::string test_data = ReadFile(config.test_path);
    std::size_t typed_data_streams = 0;
    if (!ValidateTypedBundle(test_data, &typed_data_streams, error)) {
      return false;
    }

    std::vector<std::string> training_data;
    training_data.reserve(config.training_paths.size());
    for (const std::string& path : config.training_paths) {
      training_data.push_back(ReadFile(path));
      std::size_t training_streams = 0;
      if (!ValidateTypedBundle(training_data.back(), &training_streams, error) ||
          training_streams != typed_data_streams) {
        *error = "training and test typed bundle layouts differ: " + *error;
        return false;
      }
    }
    if (config.mode != Mode::kUntrainedParser && training_data.empty()) {
      *error = "trained OpenZL modes require disjoint training chunks";
      return false;
    }

    ::openzl::Compressor compressor;
    const ZL_GraphID starting_graph =
        RegisterStartingGraph(compressor, config.mode, typed_data_streams);
    compressor.selectStartingGraph(starting_graph);

    std::string serialized;
    const auto training_started = std::chrono::steady_clock::now();
    if (config.mode == Mode::kUntrainedParser) {
      serialized = compressor.serialize();
    } else {
      const auto create_compressor = [mode = config.mode, typed_data_streams](
                                         ::openzl::poly::string_view contents) {
        return CreateFromSerialized(mode, typed_data_streams, contents);
      };
      ::openzl::training::TrainParams parameters;
      parameters.compressorGenFunc = create_compressor;
      parameters.threads = config.training_threads;
      parameters.clusteringTrainer =
          ::openzl::training::ClusteringTrainer::Greedy;
      const auto training_inputs = BuildTrainingInputs(training_data);
      const auto trained =
          ::openzl::training::train(training_inputs, compressor, parameters);
      if (trained.size() != 1) {
        throw std::runtime_error("official training returned an unexpected frontier");
      }
      serialized.assign(trained[0]->data(), trained[0]->size());
      result->training_completed = true;
    }
    const auto training_finished = std::chrono::steady_clock::now();

    auto trained_compressor =
        CreateFromSerialized(config.mode, typed_data_streams, serialized);
    ::openzl::CCtx compressor_context;
    compressor_context.refCompressor(*trained_compressor);
    compressor_context.setParameter(::openzl::CParam::FormatVersion,
                                    ZL_MAX_FORMAT_VERSION);
    compressor_context.setParameter(::openzl::CParam::PermissiveCompression,
                                    1);
    std::string frame;
    frame.resize(::openzl::compressBound(test_data.size()));
    const auto compression_started = std::chrono::steady_clock::now();
    const std::size_t compressed_size =
        compressor_context.compressSerial(frame, test_data);
    const auto compression_finished = std::chrono::steady_clock::now();
    frame.resize(compressed_size);

    ::openzl::DCtx decompressor_context;
    const auto decompression_started = std::chrono::steady_clock::now();
    const std::string restored = decompressor_context.decompressSerial(frame);
    const auto decompression_finished = std::chrono::steady_clock::now();

    std::string corrupt = frame;
    corrupt[0] = static_cast<char>(corrupt[0] ^ 0x80);
    try {
      ::openzl::DCtx corrupt_context;
      static_cast<void>(corrupt_context.decompressSerial(corrupt));
      result->corruption_rejected = false;
    } catch (const std::exception&) {
      result->corruption_rejected = true;
    }

    WriteFile(config.frame_path, frame);
    WriteFile(config.encoder_model_path, serialized);
    WriteFile(config.restored_path, restored);

    result->input_bytes = test_data.size();
    result->frame_bytes = frame.size();
    result->decoder_dependency_bytes = 0;
    result->encoder_model_bytes = serialized.size();
    result->typed_data_streams = typed_data_streams;
    result->byte_equal = restored == test_data;
    result->training_microseconds = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            training_finished - training_started)
            .count());
    result->compression_microseconds = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            compression_finished - compression_started)
            .count());
    result->decompression_microseconds = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            decompression_finished - decompression_started)
            .count());
    return result->byte_equal && result->corruption_rejected;
  } catch (const std::exception& caught) {
    *error = caught.what();
  } catch (...) {
    *error = "unknown OpenZL adapter failure";
  }
  return false;
}

}  // namespace pw::worldpack::openzl
