#ifndef PW_ZPAQ_BRIDGE_H_
#define PW_ZPAQ_BRIDGE_H_

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define PW_ZPAQ_API __attribute__((visibility("default"))) __attribute__((used))

typedef enum PWZpaqStatus {
  PW_ZPAQ_OK = 0,
  PW_ZPAQ_INVALID_ARGUMENT = 1,
  PW_ZPAQ_UNSUPPORTED_METHOD = 2,
  PW_ZPAQ_INPUT_OPEN_FAILED = 3,
  PW_ZPAQ_OUTPUT_OPEN_FAILED = 4,
  PW_ZPAQ_INPUT_READ_FAILED = 5,
  PW_ZPAQ_OUTPUT_WRITE_FAILED = 6,
  PW_ZPAQ_CODEC_FAILED = 7,
  PW_ZPAQ_SYNC_FAILED = 8,
  PW_ZPAQ_ALLOCATION_FAILED = 9,
  PW_ZPAQ_CANCELLED = 10,
} PWZpaqStatus;

PW_ZPAQ_API const char* pw_zpaq_version(void);
PW_ZPAQ_API const char* pw_zpaq_revision(void);
PW_ZPAQ_API const char* pw_zpaq_error_message(int32_t status);
PW_ZPAQ_API const char* pw_zpaq_last_error(void);

PW_ZPAQ_API int32_t pw_zpaq_compress_file(
    const char* input_path,
    const char* output_path,
    int32_t method,
    uint64_t cancellation_generation);

PW_ZPAQ_API int32_t pw_zpaq_decompress_file(
    const char* input_path,
    const char* output_path,
    uint64_t cancellation_generation);

PW_ZPAQ_API uint64_t pw_zpaq_cancellation_generation(void);
PW_ZPAQ_API void pw_zpaq_request_cancel(void);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // PW_ZPAQ_BRIDGE_H_
