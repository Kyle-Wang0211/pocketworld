#include "worldpack_alp_adapter.h"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
  if (argc != 5) {
    std::cerr << "usage: worldpack_alp_adapter float32|float64 INPUT ARCHIVE RESTORED\n";
    return 2;
  }
  pw::worldpack::alp_codec::ElementType type;
  if (std::string(argv[1]) == "float32") {
    type = pw::worldpack::alp_codec::ElementType::kFloat32;
  } else if (std::string(argv[1]) == "float64") {
    type = pw::worldpack::alp_codec::ElementType::kFloat64;
  } else {
    std::cerr << "unsupported ALP element type\n";
    return 2;
  }
  pw::worldpack::alp_codec::Result result;
  std::string error;
  if (!pw::worldpack::alp_codec::Run(type, argv[2], argv[3], argv[4], &result,
                                     &error)) {
    std::cerr << "worldpack_alp_adapter: " << error << '\n';
    return 1;
  }
  std::cout << "{\"revision\":\"" << pw::worldpack::alp_codec::Revision()
            << "\",\"input_bytes\":" << result.input_bytes
            << ",\"complete_persisted_bytes\":"
            << result.complete_persisted_bytes << ",\"alp_vectors\":"
            << result.alp_vectors << ",\"alprd_vectors\":"
            << result.alprd_vectors << ",\"padded_values\":"
            << result.padded_values << ",\"byte_equal\":"
            << (result.byte_equal ? 1 : 0) << ",\"corruption_rejected\":"
            << (result.corruption_rejected ? 1 : 0) << "}\n";
  return 0;
}
