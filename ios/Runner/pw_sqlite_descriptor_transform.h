#ifndef PW_SQLITE_DESCRIPTOR_TRANSFORM_H_
#define PW_SQLITE_DESCRIPTOR_TRANSFORM_H_

#include <stdint.h>

#if defined(__GNUC__)
#define PW_SQLITE_DESCRIPTOR_API __attribute__((visibility("default"), used))
#else
#define PW_SQLITE_DESCRIPTOR_API
#endif

#if defined(__cplusplus)
extern "C" {
#endif

typedef enum PWSQLiteDescriptorTransform {
  PW_SQLITE_DESCRIPTOR_TRANSPOSE = 1,
  PW_SQLITE_DESCRIPTOR_TRANSPOSE_XOR = 2,
  PW_SQLITE_DESCRIPTOR_TRANSPOSE_DELTA = 3,
  PW_SQLITE_DESCRIPTOR_TRACK_DELTA = 4,
} PWSQLiteDescriptorTransform;

typedef enum PWSQLiteDescriptorTransformStatus {
  PW_SQLITE_DESCRIPTOR_TRANSFORM_OK = 0,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_INVALID_ARGUMENT = 1,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_UNSUPPORTED = 2,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_INPUT_FAILED = 3,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_OUTPUT_FAILED = 4,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_SCHEMA_FAILED = 5,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_MALFORMED = 6,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_ALLOCATION_FAILED = 7,
  PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED = 8,
} PWSQLiteDescriptorTransformStatus;

typedef struct PWSQLiteDescriptorTransformStats {
  uint64_t descriptor_records;
  uint64_t descriptor_bytes;
  uint64_t overflow_pages;
  uint64_t verified_match_edges;
  uint64_t matched_descriptor_nodes;
  uint64_t predicted_descriptor_nodes;
} PWSQLiteDescriptorTransformStats;

PW_SQLITE_DESCRIPTOR_API const char*
pw_sqlite_descriptor_transform_last_error(void);

PW_SQLITE_DESCRIPTOR_API int32_t
pw_sqlite_descriptor_integrity_check_file(const char* database_path);

PW_SQLITE_DESCRIPTOR_API int32_t pw_sqlite_descriptor_transform_file(
    const char* source_path,
    const char* output_path,
    int32_t transform,
    int32_t inverse,
    PWSQLiteDescriptorTransformStats* stats);

PW_SQLITE_DESCRIPTOR_API uint64_t
pw_sqlite_descriptor_transform_cancellation_generation(void);

PW_SQLITE_DESCRIPTOR_API void
pw_sqlite_descriptor_transform_request_cancel(void);

PW_SQLITE_DESCRIPTOR_API int32_t
pw_sqlite_descriptor_transform_file_cancellable(
    const char* source_path,
    const char* output_path,
    int32_t transform,
    int32_t inverse,
    uint64_t cancellation_generation,
    PWSQLiteDescriptorTransformStats* stats);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // PW_SQLITE_DESCRIPTOR_TRANSFORM_H_
