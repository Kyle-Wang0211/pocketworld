#ifndef POCKETWORLD_XRSLAM_TRANSPORT_CORE_H_
#define POCKETWORLD_XRSLAM_TRANSPORT_CORE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PWXrslamRawPose {
  double timestamp;
  double quaternion[4];
  double translation[3];
} PWXrslamRawPose;

int32_t PWXrslamTransportCreate(const char* slam_config_path,
                                const char* device_config_path);
void PWXrslamTransportDestroy(void);

// Cross-platform fixed mechanism: one raw camera push advances the official
// generic core exactly once and returns only unclassified state/pose facts.
int32_t PWXrslamTransportPushCameraAndRunRaw(
    uint8_t* data, double timestamp, int32_t stride, int32_t camera_id,
    int32_t channel, int32_t* raw_state, PWXrslamRawPose* raw_pose);

int32_t PWXrslamTransportPushAccelerationRaw(double timestamp, double x,
                                              double y, double z);
int32_t PWXrslamTransportPushGyroscopeRaw(double timestamp, double x,
                                          double y, double z);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // POCKETWORLD_XRSLAM_TRANSPORT_CORE_H_
