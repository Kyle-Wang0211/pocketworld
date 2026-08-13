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
  PW_SQLITE_EXACT_TRANSFORM_V2 = 5,
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
  uint64_t keypoint_records;
  uint64_t keypoint_bytes;
  uint64_t match_records;
  uint64_t match_bytes;
  uint64_t two_view_records;
  uint64_t two_view_bytes;
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

// ── B1 无损形态(2026-08-11 用户签决):删描述子保匹配图 ──────────────
// 把 source 复制到 output,在副本上 DELETE FROM descriptors + VACUUM。
// source 只读不动;output 已存在则先删。返回 transform 状态码。
PW_SQLITE_DESCRIPTOR_API int32_t pw_sqlite_prune_descriptors_file(
    const char* source_path,
    const char* output_path,
    // 1 = 同时把 keypoints 的仿射形状列(a11,a12,a21,a22)裁掉,只留 x,y
    //     (cols 6/4 → 2)。仿射是匹配期的形状信息,重建只读 x,y
    //     (核 FeatureKeypointsToPointsVector);COLMAP 原生支持 cols=2。
    //     身份指纹只混 x,y,故此裁剪**不改变指纹**。
    int32_t strip_keypoint_affine,
    // 1 = 同时清空 matches 原始匹配表(只保留 two_view_geometries)。
    //     几何验证已把原始匹配蒸馏成 TVG 内点;COLMAP 建图缓存
    //     (database_cache.cc: DatabaseCache::Load)只读 TVG,不读 matches。
    int32_t drop_raw_matches);

// keypoints 的 x,y 等价摘要:按 image_id 序混入 (image_id, rows, 每点 x,y),
// **忽略 cols 与仿射列**。裁仿射前后用它证明"几何输入逐点相同"——裁后
// keypoints 表的字节必然变化,不能再用整表字节摘要做判据。
PW_SQLITE_DESCRIPTOR_API int32_t pw_sqlite_keypoints_xy_sha256(
    const char* database_path,
    char* out_hex,
    int32_t out_capacity);

// 单表内容摘要:按 rowid 序对所有列(带类型标记)做 SHA-256,写 65 字节
// hex 到 out_hex(含结尾 NUL)。用于裁剪前后逐表等同验证(全有或全无)。
PW_SQLITE_DESCRIPTOR_API int32_t pw_sqlite_table_content_sha256(
    const char* database_path,
    const char* table_name,
    char* out_hex,
    int32_t out_capacity);

// 裁剪后重新盖章 ARKPOS1 侧车的 frame_identity_digest。
//
// 核在 resume 时用 FrameIdentityDigestV1(name,camera,keypoints,descriptors)
// 重算指纹与侧车比对(official_aether_sfm_c.cc:5383)。描述子被合法裁掉后
// 指纹必然不符 → resume 拒绝重建。本函数按**裁后 DB 的真实内容**重算并
// 重写侧车(FNV-1a 载荷校验一并更新):校验面仍覆盖 帧名/相机内参/关键点/
// 记录顺序与 image_id 对应,只是不再覆盖已被合法删除的描述子字节。
//
// 只允许在 descriptors 表为空(即已裁剪)的 DB 上运行,防止被误用来给
// 任意改动过的 DB 洗白身份。
PW_SQLITE_DESCRIPTOR_API int32_t pw_sqlite_reseal_arkit_pose_digests(
    const char* database_path,
    const char* sidecar_path);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // PW_SQLITE_DESCRIPTOR_TRANSFORM_H_
