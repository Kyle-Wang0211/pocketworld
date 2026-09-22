#include "PwXrslamTransportCore.h"

#include <cmath>
#include <mutex>

#include "XRSLAM.h"

namespace {

std::mutex g_core_mutex;

bool IsFinite3(double x, double y, double z) {
  return std::isfinite(x) && std::isfinite(y) && std::isfinite(z);
}

void CopyRawPose(const XRSLAMPose& source, PWXrslamRawPose* destination) {
  if (destination == nullptr) return;
  destination->timestamp = source.timestamp;
  for (int i = 0; i < 4; ++i) {
    destination->quaternion[i] = source.quaternion[i];
  }
  for (int i = 0; i < 3; ++i) {
    destination->translation[i] = source.translation[i];
  }
}

}  // namespace

extern "C" int32_t PWXrslamTransportCreate(
    const char* slam_config_path, const char* device_config_path) {
  if (slam_config_path == nullptr || device_config_path == nullptr) return 0;
  std::lock_guard<std::mutex> lock(g_core_mutex);
  void* config = nullptr;
  return XRSLAMCreate(slam_config_path, device_config_path, "", "pocketworld",
                      &config);
}

extern "C" void PWXrslamTransportDestroy(void) {
  std::lock_guard<std::mutex> lock(g_core_mutex);
  XRSLAMDestroy();
}

extern "C" int32_t PWXrslamTransportPushCameraAndRunRaw(
    uint8_t* data, double timestamp, int32_t stride, int32_t camera_id,
    int32_t channel, int32_t* raw_state, PWXrslamRawPose* raw_pose) {
  if (data == nullptr || !std::isfinite(timestamp) || stride <= 0 ||
      channel <= 0 || raw_state == nullptr || raw_pose == nullptr) {
    return -1;
  }

  XRSLAMImage image{};
  image.data = data;
  image.timeStamp = timestamp;
  image.stride = stride;
  image.camera_id = camera_id;
  image.channel = channel;
  image.ext = nullptr;

  std::lock_guard<std::mutex> lock(g_core_mutex);
  XRSLAMPushSensorData(XRSLAM_SENSOR_CAMERA, &image);
  XRSLAMRunOneFrame();

  XRSLAMState state = XRSLAM_STATE_INITIALIZING;
  XRSLAMPose pose{};
  XRSLAMGetResult(XRSLAM_RESULT_STATE, &state);
  XRSLAMGetResult(XRSLAM_RESULT_CAMERA_POSE, &pose);
  *raw_state = static_cast<int32_t>(state);
  CopyRawPose(pose, raw_pose);
  return 0;
}

extern "C" int32_t PWXrslamTransportPushAccelerationRaw(
    double timestamp, double x, double y, double z) {
  if (!std::isfinite(timestamp) || !IsFinite3(x, y, z)) return -1;
  XRSLAMAcceleration sample{{x, y, z}, timestamp};
  std::lock_guard<std::mutex> lock(g_core_mutex);
  XRSLAMPushSensorData(XRSLAM_SENSOR_ACCELERATION, &sample);
  return 0;
}

extern "C" int32_t PWXrslamTransportPushGyroscopeRaw(
    double timestamp, double x, double y, double z) {
  if (!std::isfinite(timestamp) || !IsFinite3(x, y, z)) return -1;
  XRSLAMGyroscope sample{{x, y, z}, timestamp};
  std::lock_guard<std::mutex> lock(g_core_mutex);
  XRSLAMPushSensorData(XRSLAM_SENSOR_GYROSCOPE, &sample);
  return 0;
}
