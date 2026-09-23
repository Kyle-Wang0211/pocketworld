#ifndef POCKETWORLD_XRSLAM_TRANSPORT_CORE_H_
#define POCKETWORLD_XRSLAM_TRANSPORT_CORE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PWXrslamRawPose {
  double timestamp;
  // Frozen upstream XRSLAM camera-pose ABI order is x, y, z, w.
  double quaternion[4];
  double translation[3];
} PWXrslamRawPose;

typedef enum PWXrslamTransportStatus {
  PW_XRSLAM_OK = 0,
  PW_XRSLAM_ERR_INVALID_ARGUMENT = -1,
  PW_XRSLAM_ERR_NOT_RUNNING = -2,
  PW_XRSLAM_ERR_NON_MONOTONIC = -3,
  PW_XRSLAM_ERR_INVALID_POSE = -4
} PWXrslamTransportStatus;

typedef enum PWXrslamStream {
  PW_XRSLAM_STREAM_CAMERA = 0,
  PW_XRSLAM_STREAM_ACCELERATION = 1,
  PW_XRSLAM_STREAM_GYROSCOPE = 2
} PWXrslamStream;

typedef enum PWXrslamTransformSemantics {
  PW_XRSLAM_T_WORLD_CAMERA = 1
} PWXrslamTransformSemantics;

typedef enum PWXrslamQuaternionOrder {
  PW_XRSLAM_QUATERNION_XYZW = 1
} PWXrslamQuaternionOrder;

// Diagnostic receipt for the most recent attempted sample on one stream.
// A submitted_sequence increment proves only that the transport called the
// frozen official void push ABI; it is deliberately not named "accepted".
typedef struct PWXrslamTimestampTrace {
  int32_t stream;
  int32_t status;
  double raw_timestamp;
  double applied_offset;
  double effective_timestamp;
  uint64_t submitted_sequence;
} PWXrslamTimestampTrace;

typedef struct PWXrslamPoseMetadata {
  int32_t transform_semantics;
  int32_t quaternion_order;
} PWXrslamPoseMetadata;

typedef struct PWXrslamDestroyReceipt {
  uint64_t lifecycle_generation;
  uint64_t camera_submitted;
  uint64_t camera_run_calls;
  uint64_t acceleration_submitted;
  uint64_t gyroscope_submitted;
  uint64_t rejected_invalid_argument;
  uint64_t rejected_non_monotonic;
  uint64_t rejected_not_running;
  int32_t destroy_acknowledged;
} PWXrslamDestroyReceipt;

// Live transport receipt. XRSLAM's frozen void sensor ABI does not expose an
// internal acceptance counter, so these values mean the wrapper successfully
// called that exact ABI. They are read from the same C++ ledger used by the
// terminal Destroy receipt; Swift must not synthesize them.
typedef struct PWXrslamTransportCounters {
  uint64_t lifecycle_generation;
  uint64_t camera_submitted;
  uint64_t camera_run_calls;
  uint64_t acceleration_submitted;
  uint64_t gyroscope_submitted;
  uint64_t rejected_invalid_argument;
  uint64_t rejected_non_monotonic;
  uint64_t rejected_not_running;
  int32_t running;
} PWXrslamTransportCounters;

int32_t PWXrslamTransportCreate(const char *slam_config_path,
                                const char *device_config_path);

// Applies camera_time_offset_seconds once, at the shared transport boundary,
// before the camera sample reaches XRSLAM. IMU timestamps are unchanged.
// The return value preserves the frozen XRSLAMCreate convention: 1 success,
// 0 failure.
int32_t
PWXrslamTransportCreateWithCameraTimeOffset(const char *slam_config_path,
                                            const char *device_config_path,
                                            double camera_time_offset_seconds);

void PWXrslamTransportDestroy(void);
int32_t PWXrslamTransportDestroyWithReceipt(PWXrslamDestroyReceipt *receipt);

// Cross-platform fixed mechanism: one raw camera push advances the official
// generic core exactly once and returns only unclassified state/pose facts.
// Legacy entry point: identical to the WithIntrinsics variant below with
// k_fxfycxcy == NULL (no image extension is attached).
int32_t PWXrslamTransportPushCameraAndRunRaw(uint8_t *data, double timestamp,
                                             int32_t stride, int32_t camera_id,
                                             int32_t channel,
                                             int32_t *raw_state,
                                             PWXrslamRawPose *raw_pose);

// Same transaction, optionally carrying this frame's pinhole intrinsics.
//
// k_fxfycxcy == NULL: byte-for-byte the legacy push (XRSLAMImage zeroed,
//   ext == NULL, ext_size == 0; no extra core call).
// k_fxfycxcy != NULL: four doubles fx, fy, cx, cy, in pixels of exactly the
//   buffer passed as `data` (the caller rescales for any downsample before
//   calling). They are attached as the 72-byte XRSLAMImageExtension with
//   has_intrinsics = 1 and ext_size = sizeof(XRSLAMImageExtension), the
//   contract of fork commit 04c0e83 (xrslam-interface/src/XRSLAMImageExt.h).
//   Values the engine would reject (non-finite, fx <= 0, fy <= 0) are not
//   attached: the frame is pushed the legacy way and counted in
//   PWXrslamIntrinsicsTrace.rejected_invalid.
//   After RunOneFrame the transport reads XRSLAM_INFO_INTRINSICS once and
//   records it in the intrinsics trace, so the host can prove whether the
//   linked core consumed the per-frame K (a core without the fork change
//   keeps reporting its config K).
int32_t PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
    uint8_t *data, double timestamp, int32_t stride, int32_t camera_id,
    int32_t channel, const double *k_fxfycxcy, int32_t *raw_state,
    PWXrslamRawPose *raw_pose);

// Ledger for the per-frame intrinsics channel of the current session. The
// `last_*` fields describe the most recent successful camera push; the counts
// are session totals (reset by Create). Hosts read these; they must not
// synthesize them.
typedef struct PWXrslamIntrinsicsTrace {
  uint64_t camera_submitted_sequence; // camera submitted_sequence of the push described below
  int32_t last_per_frame_attached;    // 1 = the 72-byte ext with has_intrinsics = 1 was attached
  int32_t last_engine_report_read;    // 1 = XRSLAM_INFO_INTRINSICS was read after that push
  int32_t last_engine_report_matches; // 1 = the engine report equals the attached K bit-for-bit
  int32_t reserved;
  double last_attached_fxfycxcy[4];
  double last_engine_fxfycxcy[4];
  uint64_t attached;                  // camera pushes that carried per-frame K
  uint64_t not_attached;              // camera pushes without per-frame K (legacy or rejected)
  uint64_t rejected_invalid;          // subset of not_attached: K given but not attachable
  uint64_t engine_report_matched;     // subset of attached: engine report == attached K
} PWXrslamIntrinsicsTrace;

int32_t PWXrslamTransportGetIntrinsicsTrace(PWXrslamIntrinsicsTrace *trace);

int32_t PWXrslamTransportPushAccelerationRaw(double timestamp, double x,
                                             double y, double z);
int32_t PWXrslamTransportPushGyroscopeRaw(double timestamp, double x, double y,
                                          double z);

int32_t PWXrslamTransportGetLastTimestampTrace(int32_t stream,
                                               PWXrslamTimestampTrace *trace);

int32_t PWXrslamTransportGetPoseMetadata(PWXrslamPoseMetadata *metadata);
int32_t PWXrslamTransportGetCounters(PWXrslamTransportCounters *counters);

// Cross-platform transport preparation for a caller-owned preallocated gray
// frame slot. It preserves the versioned box-NxN half-up kernel already used
// by PocketWorld and performs no XRSLAM state transition or policy decision.
int32_t PWXrslamTransportPrepareGrayBoxNxN(
    const uint8_t *source, int32_t source_width, int32_t source_height,
    int32_t source_stride, int32_t factor, uint8_t *destination,
    int32_t destination_capacity, int32_t *destination_width,
    int32_t *destination_height);

// Intrinsics of the output of PWXrslamTransportPrepareGrayBoxNxN, given the
// intrinsics of its source buffer (both in the pixel-center-at-integer
// convention of ARKit ARCamera.intrinsics / OpenCV):
//   fx' = fx / f, fy' = fy / f, cx' = (cx + 0.5) / f - 0.5, cy' = (cy + 0.5) / f - 0.5
// This is the exact expression of the offline converter that produced the
// replay A/C evidence (arloopbench tools/pwvi_to_euroc.py:224-226,
// sha256 3c96ab11cee1401f9fd9ab2159f2c97ca0959d6533243176402ae10f10643938).
// Returns PW_XRSLAM_ERR_INVALID_ARGUMENT for factor <= 0, NULL pointers or
// non-finite input; never writes `destination` in that case.
int32_t PWXrslamTransportScaleIntrinsicsForBoxNxN(
    const double source_fxfycxcy[4], int32_t factor,
    double destination_fxfycxcy[4]);

// Converts the frozen upstream camera result (T_world_camera, quaternion xyzw)
// to a row-major 4x4 homogeneous matrix. The quaternion is normalized after
// validation; this helper never changes the algorithm result stored above.
int32_t
PWXrslamTransportPoseToWorldFromCameraMatrix(const PWXrslamRawPose *pose,
                                             double matrix_row_major_4x4[16]);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // POCKETWORLD_XRSLAM_TRANSPORT_CORE_H_
