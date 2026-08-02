#ifndef PW_WORLDPACK_OPENZL_ADAPTER_H_
#define PW_WORLDPACK_OPENZL_ADAPTER_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pw::worldpack::openzl {

enum class Mode {
  kUntrainedParser,
  kAceComplete,
  kClusteringPlusAceComplete,
};

struct Config {
  Mode mode = Mode::kUntrainedParser;
  std::vector<std::string> training_paths;
  std::string test_path;
  std::string frame_path;
  std::string encoder_model_path;
  std::string restored_path;
  std::uint32_t training_threads = 1;
};

struct Result {
  std::uint64_t input_bytes = 0;
  std::uint64_t frame_bytes = 0;
  std::uint64_t decoder_dependency_bytes = 0;
  std::uint64_t encoder_model_bytes = 0;
  std::uint64_t training_microseconds = 0;
  std::uint64_t compression_microseconds = 0;
  std::uint64_t decompression_microseconds = 0;
  std::size_t typed_data_streams = 0;
  bool training_completed = false;
  bool byte_equal = false;
  bool corruption_rejected = false;
};

const char* Version();
const char* Revision();
const char* ModeName(Mode mode);

bool ParseMode(const std::string& value, Mode* mode);
bool ValidateTypedBundle(const std::string& bundle,
                         std::size_t* typed_data_streams,
                         std::string* error);
bool Run(const Config& config, Result* result, std::string* error);

}  // namespace pw::worldpack::openzl

#endif  // PW_WORLDPACK_OPENZL_ADAPTER_H_

