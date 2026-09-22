#include "fusion_bridge/stereo_fusion_bridge.h"

#include <filesystem>
#include <iostream>

int main(int argc, char** argv) {
  if (argc != 2 || argv[1] == nullptr || argv[1][0] == '\0') {
    std::cerr << "usage: pw_official_dense_stereo_fusion <workspace>\n";
    return 2;
  }
  const std::filesystem::path workspace(argv[1]);
  const pocketworld::official_dense::fusion::Status status =
      pocketworld::official_dense::fusion::RunStereoFusion(workspace,
                                                            "geometric");
  if (!status.ok()) {
    std::cerr << status.message << '\n';
    return 1;
  }
  std::cout << (workspace / "fused.ply").string() << '\n';
  return 0;
}
