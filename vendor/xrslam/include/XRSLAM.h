/**
 * C-compatible declaration mirror for OpenXRLab XRSLAM 0.5.0.
 *
 * Algorithm binary authority:
 *   https://github.com/openxrlab/xrslam
 *   commit 4beb1a942f33da9afbfae2d70e2c641cfc2bb675
 *
 * The upstream header places a std::vector-backed debug type in its public
 * declarations, which cannot be imported by Swift's Objective-C bridge. This
 * mirror declares only the upstream ABI-safe types used by the product. It
 * does not add functions, return codes, or algorithm behavior.
 *
 * Per-frame intrinsics layout (2026-09-23). The two image structs below follow
 * the fork header at https://github.com/Kyle-Wang0211/xrslam commit
 * 04c0e83e9c4889612880529dd49dd8063819a776,
 * xrslam-interface/include/XRSLAM.h:38-73:
 *   - XRSLAMImageExtension keeps the upstream 32-byte prefix unchanged and
 *     appends intrinsics_fxfycxcy[4] + has_intrinsics + reserved_pad
 *     (72 bytes total);
 *   - XRSLAMImage stays 40 bytes; ext_size occupies the 4 bytes of padding
 *     that upstream already had between `channel` and `ext`.
 * The fork engine reads the appended fields only when ext_size equals exactly
 * sizeof(XRSLAMImageExtension) (fork xrslam-interface/src/XRSLAMImageExt.h:49-66).
 * The unmodified upstream core (4beb1a9, shipping archive) never reads ext or
 * the padding, so a zero-initialized XRSLAMImage with ext == NULL is the same
 * input for both cores. Layout is pinned by static_asserts in
 * transport/PwXrslamTransportCore.cpp.
 */

#ifndef POCKETWORLD_XRSLAM_OFFICIAL_ABI_H_
#define POCKETWORLD_XRSLAM_OFFICIAL_ABI_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum XRSLAMSensorType {
  XRSLAM_SENSOR_CAMERA = 0,
  XRSLAM_SENSOR_DEPTH_CAMERA,
  XRSLAM_SENSOR_ACCELERATION,
  XRSLAM_SENSOR_GYROSCOPE,
  XRSLAM_SENSOR_GRAVITY,
  XRSLAM_SENSOR_ROTATION_VECTOR,
  XRSLAM_SENSOR_UNKNOWN
} XRSLAMSensorType;

typedef struct XRSLAMImageExtension {
  double exposure_time;
  double default_focus_distance;
  double focal_length;
  double focus_distance;
  /* Appended by fork 04c0e83 (XRSLAM.h:44-47). Pinhole K of the pushed pixel
     buffer, in pixels: fx, fy, cx, cy. */
  double intrinsics_fxfycxcy[4];
  int has_intrinsics; /* == 1 => intrinsics_fxfycxcy valid; any other value = invalid. */
  int reserved_pad;   /* caller sets 0. */
} XRSLAMImageExtension;

/* Size of the upstream 32-byte extension (fork XRSLAM.h:51). */
#define XRSLAM_IMAGE_EXTENSION_LEGACY_SIZE 32u

typedef struct XRSLAMImage {
  unsigned char *data;
  double timeStamp;
  int stride;
  int camera_id;
  int channel;
  /* Fork 04c0e83 (XRSLAM.h:63-71): sizeof(*ext) as compiled by the caller;
     0 = legacy. Lives in upstream's existing padding, struct stays 40 bytes. */
  unsigned int ext_size;
  XRSLAMImageExtension *ext;
} XRSLAMImage;

typedef struct XRSLAMDepthImage {
  uint16_t *data;
  uint16_t *confidence;
  double timeStamp;
} XRSLAMDepthImage;

typedef struct XRSLAMAcceleration {
  double data[3];
  double timestamp;
} XRSLAMAcceleration;

typedef struct XRSLAMGyroscope {
  double data[3];
  double timestamp;
} XRSLAMGyroscope;

typedef struct XRSLAMGravity {
  double data[3];
  double timestamp;
} XRSLAMGravity;

typedef struct XRSLAMRotationVector {
  double data[4];
  double timestamp;
} XRSLAMRotationVector;

typedef enum XRSLAMResultType {
  XRSLAM_RESULT_BODY_POSE = 0,
  XRSLAM_RESULT_CAMERA_POSE,
  XRSLAM_RESULT_STATE,
  XRSLAM_RESULT_LANDMARKS,
  XRSLAM_RESULT_FEATURES,
  XRSLAM_RESULT_BIAS,
  XRSLAM_RESULT_DEBUG_LOGS,
  XRSLAM_RESULT_VERSION,
  XRSLAM_RESULT_UNKNOWN,
  XRSLAM_INFO_INTRINSICS
} XRSLAMResultType;

typedef struct XRSLAMPose {
  double quaternion[4];
  double translation[3];
  double timestamp;
} XRSLAMPose;

typedef struct XRSLAMIntrinsics {
  double fx;
  double fy;
  double cx;
  double cy;
} XRSLAMIntrinsics;

typedef enum XRSLAMState {
  XRSLAM_STATE_INITIALIZING = 0,
  XRSLAM_STATE_TRACKING_SUCCESS,
  XRSLAM_STATE_TRACKING_FAIL
} XRSLAMState;

typedef struct XRSLAMBias {
  double data[3];
} XRSLAMBias;

typedef struct XRSLAMIMUBias {
  XRSLAMBias acc_bias;
  XRSLAMBias gyr_bias;
} XRSLAMIMUBias;

int XRSLAMCreate(const char *slam_config_path,
                 const char *device_config_path,
                 const char *license_path,
                 const char *product_name,
                 void **config);
void XRSLAMPushSensorData(XRSLAMSensorType sensor_type, void *sensor_data);
void XRSLAMRunOneFrame(void);
void XRSLAMGetResult(XRSLAMResultType result_type, void *result_data);
void XRSLAMDestroy(void);

#ifdef __cplusplus
}
#endif

#endif  // POCKETWORLD_XRSLAM_OFFICIAL_ABI_H_
