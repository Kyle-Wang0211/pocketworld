#ifndef PW_LEPTON_BRIDGE_H_
#define PW_LEPTON_BRIDGE_H_

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define PW_LEPTON_API \
  __attribute__((visibility("default"))) __attribute__((used))

typedef enum PWLeptonStatus {
  PW_LEPTON_OK = 0,
  PW_LEPTON_INVALID_ARGUMENT = 1,
  PW_LEPTON_FILE_IO_FAILED = 2,
  PW_LEPTON_CODEC_FAILED = 3,
  PW_LEPTON_PANIC = 4,
  PW_LEPTON_CANCELLED = 5,
} PWLeptonStatus;

PW_LEPTON_API const char* pw_lepton_version(void);
PW_LEPTON_API const char* pw_lepton_revision(void);
PW_LEPTON_API const char* pw_lepton_error_message(int32_t status);

PW_LEPTON_API int32_t pw_lepton_encode_jpeg_file(
    const char* jpeg_path,
    const char* lepton_path,
    uint64_t* elapsed_microseconds);

PW_LEPTON_API int32_t pw_lepton_reconstruct_jpeg_file(
    const char* lepton_path,
    const char* jpeg_path,
    uint64_t* elapsed_microseconds);

PW_LEPTON_API uint64_t pw_lepton_cancellation_generation(void);
PW_LEPTON_API void pw_lepton_request_cancel(void);

PW_LEPTON_API int32_t pw_lepton_encode_jpeg_file_cancellable(
    const char* jpeg_path,
    const char* lepton_path,
    uint64_t expected_generation,
    uint64_t* elapsed_microseconds);

PW_LEPTON_API int32_t pw_lepton_reconstruct_jpeg_file_cancellable(
    const char* lepton_path,
    const char* jpeg_path,
    uint64_t expected_generation,
    uint64_t* elapsed_microseconds);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // PW_LEPTON_BRIDGE_H_
