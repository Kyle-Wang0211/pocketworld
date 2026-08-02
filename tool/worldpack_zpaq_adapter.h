#ifndef PW_WORLDPACK_ZPAQ_ADAPTER_H_
#define PW_WORLDPACK_ZPAQ_ADAPTER_H_

#include <cstdint>
#include <string>

namespace pw::worldpack::zpaq {

struct Result {
  std::uint64_t input_bytes = 0;
  std::uint64_t complete_persisted_bytes = 0;
  std::uint64_t elapsed_microseconds = 0;
};

const char* Version();
const char* SourceSha256();

bool CompressFile(const std::string& input_path,
                  const std::string& archive_path,
                  int method,
                  Result* result,
                  std::string* error);

bool DecompressFile(const std::string& archive_path,
                    const std::string& output_path,
                    Result* result,
                    std::string* error);

}  // namespace pw::worldpack::zpaq

#endif  // PW_WORLDPACK_ZPAQ_ADAPTER_H_

