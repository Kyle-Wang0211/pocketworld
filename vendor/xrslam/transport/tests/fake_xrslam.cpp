#include "fake_xrslam.h"

#include <condition_variable>
#include <cstring>
#include <mutex>

FakeXrslamCalls g_fake_calls;
int g_fake_create_result = 1;
XRSLAMState g_fake_state = XRSLAM_STATE_TRACKING_SUCCESS;
XRSLAMPose g_fake_pose{};

namespace {
std::mutex g_run_mutex;
std::condition_variable g_run_condition;
bool g_block_run = false;
bool g_run_entered = false;
bool g_run_released = false;
bool g_run_completed = false;
bool g_destroy_observed_completed_run = false;
} // namespace

void FakeXrslamReset() {
  g_fake_calls = {};
  g_fake_create_result = 1;
  g_fake_state = XRSLAM_STATE_TRACKING_SUCCESS;
  g_fake_pose = {};
  g_fake_pose.quaternion[3] = 1.0;
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
    g_fake_calls.last_camera_timestamp =
        static_cast<XRSLAMImage *>(data)->timeStamp;
  } else if (type == XRSLAM_SENSOR_ACCELERATION) {
    ++g_fake_calls.acceleration_push;
    g_fake_calls.last_acceleration_timestamp =
        static_cast<XRSLAMAcceleration *>(data)->timestamp;
  } else if (type == XRSLAM_SENSOR_GYROSCOPE) {
    ++g_fake_calls.gyroscope_push;
    g_fake_calls.last_gyroscope_timestamp =
        static_cast<XRSLAMGyroscope *>(data)->timestamp;
  }
}

extern "C" void XRSLAMRunOneFrame() {
  ++g_fake_calls.run;
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
    *static_cast<XRSLAMState *>(result) = g_fake_state;
  } else if (type == XRSLAM_RESULT_CAMERA_POSE) {
    *static_cast<XRSLAMPose *>(result) = g_fake_pose;
  }
}

extern "C" void XRSLAMDestroy() {
  std::lock_guard<std::mutex> lock(g_run_mutex);
  g_destroy_observed_completed_run = g_run_completed;
  ++g_fake_calls.destroy;
}
