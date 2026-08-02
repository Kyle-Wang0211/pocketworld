#include "worldpack_openzl_adapter.h"

#include <cstdint>
#include <iostream>
#include <string>

int main(int argc, char** argv) {
  if (argc < 6) {
    std::cerr << "usage: worldpack_openzl_adapter MODE TEST FRAME MODEL RESTORED [TRAIN ...]\n";
    return 2;
  }
  pw::worldpack::openzl::Mode mode;
  if (!pw::worldpack::openzl::ParseMode(argv[1], &mode)) {
    std::cerr << "unsupported OpenZL mode\n";
    return 2;
  }
  pw::worldpack::openzl::Config config;
  config.mode = mode;
  config.test_path = argv[2];
  config.frame_path = argv[3];
  config.encoder_model_path = argv[4];
  config.restored_path = argv[5];
  config.training_threads = 8;
  for (int index = 6; index < argc; ++index) {
    config.training_paths.emplace_back(argv[index]);
  }
  pw::worldpack::openzl::Result result;
  std::string error;
  if (!pw::worldpack::openzl::Run(config, &result, &error)) {
    std::cerr << "worldpack_openzl_adapter: " << error << '\n';
    return 1;
  }
  std::cout << "{\"mode\":\"" << pw::worldpack::openzl::ModeName(mode)
            << "\",\"input_bytes\":" << result.input_bytes
            << ",\"frame_bytes\":" << result.frame_bytes
            << ",\"decoder_dependency_bytes\":"
            << result.decoder_dependency_bytes
            << ",\"encoder_model_bytes\":" << result.encoder_model_bytes
            << ",\"training_microseconds\":"
            << result.training_microseconds
            << ",\"compression_microseconds\":"
            << result.compression_microseconds
            << ",\"decompression_microseconds\":"
            << result.decompression_microseconds
            << ",\"typed_data_streams\":" << result.typed_data_streams
            << ",\"training_completed\":"
            << (result.training_completed ? 1 : 0)
            << ",\"byte_equal\":" << (result.byte_equal ? 1 : 0)
            << ",\"corruption_rejected\":"
            << (result.corruption_rejected ? 1 : 0) << "}\n";
  return 0;
}
