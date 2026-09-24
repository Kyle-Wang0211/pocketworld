#include "fake_xrslam.h"

#include <condition_variable>
#include <cstring>
#include <mutex>

FakeXrslamCalls g_fake_calls;
int g_fake_create_result = 1;
XRSLAMState g_fake_state = XRSLAM_STATE_TRACKING_SUCCESS;
XRSLAMPose g_fake_pose{};
XRSLAMIntrinsics g_fake_config_intrinsics{};
FakeIntrinsicsMode g_fake_intrinsics_mode = kFakeIntrinsicsConfigOnly;

namespace {
std::mutex g_run_mutex;
std::condition_variable g_run_condition;
bool g_block_run = false;
bool g_run_entered = false;
bool g_run_released = false;
bool g_run_completed = false;
bool g_destroy_observed_completed_run = false;
bool g_fake_has_latest_intrinsics = false;
XRSLAMIntrinsics g_fake_latest_intrinsics{};
} // namespace

void FakeXrslamReset() {
  g_fake_calls = {};
  g_fake_create_result = 1;
  g_fake_state = XRSLAM_STATE_TRACKING_SUCCESS;
  g_fake_pose = {};
  g_fake_pose.quaternion[3] = 1.0;
  g_fake_config_intrinsics = {1000.0, 1000.0, 640.0, 360.0};
  g_fake_intrinsics_mode = kFakeIntrinsicsConfigOnly;
  g_fake_has_latest_intrinsics = false;
  g_fake_latest_intrinsics = {};
  std::lock_guard<std::mutex> lock(g_run_mutex);
  g_block_run = false;
  g_run_entered = false;
  g_run_released = false;
  g_run_completed = false;
  g_destroy_observed_completed_run = false;
}

void FakeXrslamBlockRun() {
  std::lock_guard<std::mutex> lock(g_run_mutex);
  g_block_run = true;
  g_run_released = false;
}

void FakeXrslamWaitForRunEntry() {
  std::unique_lock<std::mutex> lock(g_run_mutex);
  g_run_condition.wait(lock, [] { return g_run_entered; });
}

void FakeXrslamReleaseRun() {
  std::lock_guard<std::mutex> lock(g_run_mutex);
  g_run_released = true;
  g_run_condition.notify_all();
}

bool FakeXrslamDestroyObservedCompletedRun() {
  std::lock_guard<std::mutex> lock(g_run_mutex);
  return g_destroy_observed_completed_run;
}

extern "C" int XRSLAMCreate(const char *, const char *, const char *,
                            const char *, void **config) {
  ++g_fake_calls.create;
  if (config != nullptr)
    *config = g_fake_create_result == 1 ? config : nullptr;
  return g_fake_create_result;
}

extern "C" void XRSLAMPushSensorData(XRSLAMSensorType type, void *data) {
  if (type == XRSLAM_SENSOR_CAMERA) {
    ++g_fake_calls.camera_push;
    g_fake_calls.sequence.push_back(kFakeCallPushCamera);
    const XRSLAMImage *image = static_cast<XRSLAMImage *>(data);
    g_fake_calls.last_camera_timestamp = image->timeStamp;
    std::memcpy(g_fake_calls.last_image_bytes, image, sizeof(XRSLAMImage));
    std::memset(g_fake_calls.last_ext_bytes, 0,
                sizeof(g_fake_calls.last_ext_bytes));
    g_fake_calls.last_ext_present = image->ext != nullptr;
    g_fake_calls.last_ext_copied = 0;
    if (image->ext != nullptr) {
      const unsigned int n =
          image->ext_size == sizeof(XRSLAMImageExtension)
              ? static_cast<unsigned int>(sizeof(XRSLAMImageExtension))
              : XRSLAM_IMAGE_EXTENSION_LEGACY_SIZE;
      std::memcpy(g_fake_calls.last_ext_bytes, image->ext, n);
      g_fake_calls.last_ext_copied = n;
      // Fork 04c0e83 acceptance rule (XRSLAMImageExt.h:49-66).
      const XRSLAMImageExtension *e = image->ext;
      if (image->ext_size == sizeof(XRSLAMImageExtension) &&
          e->has_intrinsics == 1 && e->intrinsics_fxfycxcy[0] > 0.0 &&
          e->intrinsics_fxfycxcy[1] > 0.0) {
        g_fake_has_latest_intrinsics = true;
        g_fake_latest_intrinsics = {
            e->intrinsics_fxfycxcy[0], e->intrinsics_fxfycxcy[1],
            e->intrinsics_fxfycxcy[2], e->intrinsics_fxfycxcy[3]};
      }
    }
  } else if (type == XRSLAM_SENSOR_ACCELERATION) {
    ++g_fake_calls.acceleration_push;
    g_fake_calls.sequence.push_back(kFakeCallPushAcceleration);
    g_fake_calls.last_acceleration_timestamp =
        static_cast<XRSLAMAcceleration *>(data)->timestamp;
  } else if (type == XRSLAM_SENSOR_GYROSCOPE) {
    ++g_fake_calls.gyroscope_push;
    g_fake_calls.sequence.push_back(kFakeCallPushGyroscope);
    g_fake_calls.last_gyroscope_timestamp =
        static_cast<XRSLAMGyroscope *>(data)->timestamp;
  }
}

extern "C" void XRSLAMRunOneFrame() {
  ++g_fake_calls.run;
  g_fake_calls.sequence.push_back(kFakeCallRun);
  std::unique_lock<std::mutex> lock(g_run_mutex);
  g_run_entered = true;
  g_run_condition.notify_all();
  if (g_block_run) {
    g_run_condition.wait(lock, [] { return g_run_released; });
  }
  g_run_completed = true;
}

extern "C" void XRSLAMGetResult(XRSLAMResultType type, void *result) {
  ++g_fake_calls.get_result;
  if (type == XRSLAM_RESULT_STATE) {
    g_fake_calls.sequence.push_back(kFakeCallGetState);
    *static_cast<XRSLAMState *>(result) = g_fake_state;
  } else if (type == XRSLAM_RESULT_CAMERA_POSE) {
    g_fake_calls.sequence.push_back(kFakeCallGetCameraPose);
    *static_cast<XRSLAMPose *>(result) = g_fake_pose;
  } else if (type == XRSLAM_INFO_INTRINSICS) {
    g_fake_calls.sequence.push_back(kFakeCallGetIntrinsics);
    *static_cast<XRSLAMIntrinsics *>(result) =
        g_fake_intrinsics_mode == kFakeIntrinsicsForkLatest &&
                g_fake_has_latest_intrinsics
            ? g_fake_latest_intrinsics
            : g_fake_config_intrinsics;
  } else {
    g_fake_calls.sequence.push_back(kFakeCallGetOther);
  }
}

extern "C" void XRSLAMDestroy() {
  std::lock_guard<std::mutex> lock(g_run_mutex);
  g_destroy_observed_completed_run = g_run_completed;
  ++g_fake_calls.destroy;
  // Fork 04c0e83 XRSLAMManager::Destroy clears the latest per-frame K
  // (XRSLAMManager.cpp:117-120).
  g_fake_has_latest_intrinsics = false;
}
