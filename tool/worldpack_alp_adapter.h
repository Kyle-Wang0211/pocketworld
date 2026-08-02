#ifndef PW_WORLDPACK_ALP_ADAPTER_H_
#define PW_WORLDPACK_ALP_ADAPTER_H_

#include <cstdint>
#include <string>

namespace pw::worldpack::alp_codec {

enum class ElementType : std::uint8_t {
  kFloat32 = 1,
  kFloat64 = 2,
};

struct Result {
  std::uint64_t input_bytes = 0;
  std::uint64_t complete_persisted_bytes = 0;
  std::uint64_t alp_vectors = 0;
  std::uint64_t alprd_vectors = 0;
  std::uint64_t padded_values = 0;
  bool byte_equal = false;
  bool corruption_rejected = false;
};

const char* Revision();

bool Run(ElementType type,
         const std::string& input_path,
         const std::string& archive_path,
         const std::string& restored_path,
         Result* result,
         std::string* error);

bool DecompressFile(const std::string& archive_path,
                    const std::string& restored_path,
                    Result* result,
                    std::string* error);

}  // namespace pw::worldpack::alp_codec

#endif  // PW_WORLDPACK_ALP_ADAPTER_H_
