#ifndef PW_JXL_BRIDGE_H_
#define PW_JXL_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define PW_JXL_API __attribute__((visibility("default"))) __attribute__((used))

typedef struct PWJXLBuffer {
  uint8_t* data;
  size_t size;
} PWJXLBuffer;

typedef enum PWJXLStatus {
  PW_JXL_OK = 0,
  PW_JXL_INVALID_ARGUMENT = 1,
  PW_JXL_ALLOCATION_FAILED = 2,
  PW_JXL_ENCODER_CREATE_FAILED = 3,
  PW_JXL_ENCODER_RUNNER_FAILED = 4,
  PW_JXL_ENCODER_CONFIG_FAILED = 5,
  PW_JXL_ENCODER_FRAME_FAILED = 6,
  PW_JXL_ENCODER_OUTPUT_FAILED = 7,
  PW_JXL_DECODER_CREATE_FAILED = 8,
  PW_JXL_DECODER_RUNNER_FAILED = 9,
  PW_JXL_DECODER_INPUT_FAILED = 10,
  PW_JXL_DECODER_OUTPUT_FAILED = 11,
  PW_JXL_NO_JPEG_RECONSTRUCTION = 12,
  PW_JXL_FILE_IO_FAILED = 13,
  PW_JXL_CANCELLED = 14,
} PWJXLStatus;

PW_JXL_API const char* pw_jxl_version(void);
PW_JXL_API const char* pw_jxl_revision(void);
PW_JXL_API const char* pw_jxl_error_message(int32_t status);

PW_JXL_API int32_t pw_jxl_encode_jpeg_file(
    const char* jpeg_path,
    const char* jxl_path,
    int32_t effort,
    uint64_t* elapsed_microseconds);

PW_JXL_API int32_t pw_jxl_reconstruct_jpeg_file(
    const char* jxl_path,
    const char* jpeg_path,
    uint64_t* elapsed_microseconds);

PW_JXL_API uint64_t pw_jxl_cancellation_generation(void);
PW_JXL_API void pw_jxl_request_cancel(void);

PW_JXL_API int32_t pw_jxl_encode_jpeg_file_cancellable(
    const char* jpeg_path,
    const char* jxl_path,
    int32_t effort,
    uint64_t cancellation_generation,
    uint64_t* elapsed_microseconds);

PW_JXL_API int32_t pw_jxl_reconstruct_jpeg_file_cancellable(
    const char* jxl_path,
    const char* jpeg_path,
    uint64_t cancellation_generation,
    uint64_t* elapsed_microseconds);

PW_JXL_API int32_t pw_jxl_encode_jpeg(const uint8_t* jpeg_data,
                                      size_t jpeg_size,
                                      int32_t effort,
                                      PWJXLBuffer* output,
                                      uint64_t* elapsed_microseconds);

PW_JXL_API int32_t pw_jxl_reconstruct_jpeg(
    const uint8_t* jxl_data,
    size_t jxl_size,
    PWJXLBuffer* output,
    uint64_t* elapsed_microseconds);

PW_JXL_API void pw_jxl_buffer_free(PWJXLBuffer* buffer);

PW_JXL_API uint64_t pw_process_resident_bytes(void);
PW_JXL_API uint64_t pw_process_peak_resident_bytes(void);
PW_JXL_API int32_t pw_process_thermal_state(void);
PW_JXL_API const char* pw_documents_path(void);
PW_JXL_API const char* pw_device_model(void);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // PW_JXL_BRIDGE_H_
