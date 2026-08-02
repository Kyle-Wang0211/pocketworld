#include "worldpack_zpaq_adapter.h"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
  if (argc != 4) {
    std::cerr << "usage: worldpack_zpaq_adapter compress|decompress INPUT OUTPUT\n";
    return 2;
  }
  pw::worldpack::zpaq::Result result;
  std::string error;
  bool ok = false;
  if (std::string(argv[1]) == "compress") {
    ok = pw::worldpack::zpaq::CompressFile(argv[2], argv[3], 5, &result, &error);
  } else if (std::string(argv[1]) == "decompress") {
    ok = pw::worldpack::zpaq::DecompressFile(argv[2], argv[3], &result, &error);
  } else {
    std::cerr << "unsupported operation\n";
    return 2;
  }
  if (!ok) {
    std::cerr << "worldpack_zpaq_adapter: " << error << '\n';
    return 1;
  }
  std::cout << "{\"version\":\"" << pw::worldpack::zpaq::Version()
            << "\",\"source_sha256\":\""
            << pw::worldpack::zpaq::SourceSha256()
            << "\",\"input_bytes\":" << result.input_bytes
            << ",\"complete_persisted_bytes\":"
            << result.complete_persisted_bytes
            << ",\"elapsed_microseconds\":" << result.elapsed_microseconds
            << "}\n";
  return 0;
}

