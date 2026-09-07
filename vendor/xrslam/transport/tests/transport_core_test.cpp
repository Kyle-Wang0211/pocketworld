#include "PwXrslamTransportCore.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <thread>

#include "fake_xrslam.h"

namespace {

void Check(bool condition, const char *expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression << '\n';
    std::exit(1);
  }
}

#define CHECK(expression) Check((expression), #expression, __LINE__)

bool Near(double a, double b, double tolerance = 1e-12) {
  return std::abs(a - b) <= tolerance;
}

void TestOffsetAppliedExactlyOnceAndOneRunPerCamera() {
  FakeXrslamReset();
  CHECK(PWXrslamTransportCreateWithCameraTimeOffset("slam", "device", 0.125) ==
        1);

  std::array<uint8_t, 16> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 10.0, 4, 0, 1,
                                             &state, &pose) == PW_XRSLAM_OK);
  CHECK(g_fake_calls.camera_push == 1);
  CHECK(g_fake_calls.run == 1);
  CHECK(Near(g_fake_calls.last_camera_timestamp, 10.125));

  PWXrslamTimestampTrace trace{};
  CHECK(PWXrslamTransportGetLastTimestampTrace(PW_XRSLAM_STREAM_CAMERA,
                                               &trace) == PW_XRSLAM_OK);
  CHECK(Near(trace.raw_timestamp, 10.0));
  CHECK(Near(trace.applied_offset, 0.125));
  CHECK(Near(trace.effective_timestamp, 10.125));
  CHECK(trace.submitted_sequence == 1);

  PWXrslamTransportCounters live{};
  CHECK(PWXrslamTransportGetCounters(&live) == PW_XRSLAM_OK);
  CHECK(live.lifecycle_generation == 1);
  CHECK(live.running == 1);
  CHECK(live.camera_submitted == 1);
  CHECK(live.camera_run_calls == 1);
  CHECK(live.acceleration_submitted == 0);
  CHECK(live.gyroscope_submitted == 0);

  PWXrslamDestroyReceipt receipt{};
  CHECK(PWXrslamTransportDestroyWithReceipt(&receipt) == PW_XRSLAM_OK);
  CHECK(receipt.destroy_acknowledged == 1);
  CHECK(receipt.camera_submitted == 1);
  CHECK(receipt.camera_run_calls == 1);
}

void TestPreparesExactBoxDownsampleIntoCallerPool() {
  const std::array<uint8_t, 16> source = {
      0, 2, 10, 12,
      4, 6, 14, 16,
      20, 22, 30, 32,
      24, 26, 34, 36,
  };
  std::array<uint8_t, 4> destination{};
  int32_t width = 0;
  int32_t height = 0;
  CHECK(PWXrslamTransportPrepareGrayBoxNxN(
            source.data(), 4, 4, 4, 2, destination.data(),
            static_cast<int32_t>(destination.size()), &width, &height) ==
        PW_XRSLAM_OK);
  CHECK(width == 2);
  CHECK(height == 2);
  CHECK(destination[0] == 3);
  CHECK(destination[1] == 13);
  CHECK(destination[2] == 23);
  CHECK(destination[3] == 33);

  CHECK(PWXrslamTransportPrepareGrayBoxNxN(
            source.data(), 4, 4, 4, 3, destination.data(),
            static_cast<int32_t>(destination.size()), &width, &height) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
}

void TestNegativeOffsetAppliedExactlyOnce() {
  FakeXrslamReset();
  CHECK(PWXrslamTransportCreateWithCameraTimeOffset("slam", "device", -0.25) ==
        1);
  std::array<uint8_t, 16> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 4.0, 4, 0, 1,
                                             &state, &pose) == PW_XRSLAM_OK);
  CHECK(Near(g_fake_calls.last_camera_timestamp, 3.75));
  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
}

void TestRejectsNonFiniteRollbackAndStoppedBeforeAbi() {
  FakeXrslamReset();
  std::array<uint8_t, 16> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 1.0, 4, 0, 1,
                                             &state, &pose) ==
        PW_XRSLAM_ERR_NOT_RUNNING);
  CHECK(g_fake_calls.camera_push == 0);

  CHECK(PWXrslamTransportCreateWithCameraTimeOffset("slam", "device", 0.1) ==
        1);
  CHECK(PWXrslamTransportPushCameraAndRunRaw(
            pixels.data(), std::numeric_limits<double>::infinity(), 4, 0, 1,
            &state, &pose) == PW_XRSLAM_ERR_INVALID_ARGUMENT);
  CHECK(g_fake_calls.camera_push == 0);
  CHECK(PWXrslamTransportPushAccelerationRaw(1.0, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_OK);
  CHECK(PWXrslamTransportPushAccelerationRaw(1.0, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_ERR_NON_MONOTONIC);
  CHECK(PWXrslamTransportPushAccelerationRaw(0.9, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_ERR_NON_MONOTONIC);
  CHECK(PWXrslamTransportPushAccelerationRaw(
            2.0, std::numeric_limits<double>::quiet_NaN(), 2.0, 3.0) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
  CHECK(g_fake_calls.acceleration_push == 1);

  CHECK(PWXrslamTransportPushGyroscopeRaw(3.0, 1.0, 2.0, 3.0) == PW_XRSLAM_OK);
  CHECK(PWXrslamTransportPushGyroscopeRaw(
            std::numeric_limits<double>::quiet_NaN(), 1.0, 2.0, 3.0) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
  CHECK(PWXrslamTransportPushGyroscopeRaw(2.0, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_ERR_NON_MONOTONIC);
  CHECK(g_fake_calls.gyroscope_push == 1);

  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 5.0, 4, 0, 1,
                                             &state, &pose) == PW_XRSLAM_OK);
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 4.9, 4, 0, 1,
                                             &state, &pose) ==
        PW_XRSLAM_ERR_NON_MONOTONIC);
  CHECK(g_fake_calls.camera_push == 1);
  CHECK(g_fake_calls.run == 1);

  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
  const FakeXrslamCalls at_destroy = g_fake_calls;
  CHECK(PWXrslamTransportPushGyroscopeRaw(4.0, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_ERR_NOT_RUNNING);
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 6.0, 4, 0, 1,
                                             &state, &pose) ==
        PW_XRSLAM_ERR_NOT_RUNNING);
  CHECK(g_fake_calls.destroy == at_destroy.destroy);
  CHECK(g_fake_calls.camera_push == at_destroy.camera_push);
  CHECK(g_fake_calls.gyroscope_push == at_destroy.gyroscope_push);
  CHECK(g_fake_calls.run == at_destroy.run);
}

void TestCreateFailureDoesNotOpenRunningGate() {
  FakeXrslamReset();
  g_fake_create_result = 0;
  CHECK(PWXrslamTransportCreateWithCameraTimeOffset("slam", "device", 0.0) ==
        0);
  CHECK(PWXrslamTransportPushAccelerationRaw(1.0, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_ERR_NOT_RUNNING);
  CHECK(g_fake_calls.acceleration_push == 0);
  PWXrslamDestroyReceipt receipt{};
  CHECK(PWXrslamTransportDestroyWithReceipt(&receipt) ==
        PW_XRSLAM_ERR_NOT_RUNNING);
  CHECK(receipt.destroy_acknowledged == 0);
  CHECK(g_fake_calls.destroy == 0);
}

void TestSuccessfulRecreateStartsANewTimestampGeneration() {
  FakeXrslamReset();
  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  CHECK(PWXrslamTransportPushAccelerationRaw(9.0, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_OK);
  PWXrslamDestroyReceipt first{};
  CHECK(PWXrslamTransportDestroyWithReceipt(&first) == PW_XRSLAM_OK);

  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  CHECK(PWXrslamTransportPushAccelerationRaw(1.0, 1.0, 2.0, 3.0) ==
        PW_XRSLAM_OK);
  PWXrslamDestroyReceipt second{};
  CHECK(PWXrslamTransportDestroyWithReceipt(&second) == PW_XRSLAM_OK);
  CHECK(second.lifecycle_generation == first.lifecycle_generation + 1);
  CHECK(first.acceleration_submitted == 1);
  CHECK(second.acceleration_submitted == 1);
}

void TestDestroyIsABarrierForAnInFlightCameraRun() {
  FakeXrslamReset();
  FakeXrslamBlockRun();
  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  std::array<uint8_t, 16> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  int32_t camera_result = PW_XRSLAM_ERR_INVALID_ARGUMENT;
  std::thread camera([&] {
    camera_result = PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 1.0, 4,
                                                         0, 1, &state, &pose);
  });
  FakeXrslamWaitForRunEntry();

  std::atomic<bool> destroy_call_started{false};
  int32_t destroy_result = PW_XRSLAM_ERR_INVALID_ARGUMENT;
  PWXrslamDestroyReceipt receipt{};
  std::thread destroy([&] {
    destroy_call_started.store(true, std::memory_order_release);
    destroy_result = PWXrslamTransportDestroyWithReceipt(&receipt);
  });
  while (!destroy_call_started.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }

  FakeXrslamReleaseRun();
  camera.join();
  destroy.join();
  CHECK(camera_result == PW_XRSLAM_OK);
  CHECK(destroy_result == PW_XRSLAM_OK);
  CHECK(FakeXrslamDestroyObservedCompletedRun());
  CHECK(receipt.camera_submitted == 1);
  CHECK(receipt.camera_run_calls == 1);
  CHECK(receipt.destroy_acknowledged == 1);
}

void TestWorldFromCameraXyzwGolden() {
  FakeXrslamReset();
  constexpr double kSqrtHalf = 0.70710678118654752440;
  g_fake_pose.timestamp = 7.0;
  g_fake_pose.quaternion[0] = 0.0;
  g_fake_pose.quaternion[1] = 0.0;
  g_fake_pose.quaternion[2] = kSqrtHalf;
  g_fake_pose.quaternion[3] = kSqrtHalf;
  g_fake_pose.translation[0] = 1.0;
  g_fake_pose.translation[1] = 2.0;
  g_fake_pose.translation[2] = 3.0;

  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  std::array<uint8_t, 16> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 7.0, 4, 0, 1,
                                             &state, &pose) == PW_XRSLAM_OK);
  CHECK(state == XRSLAM_STATE_TRACKING_SUCCESS);

  PWXrslamPoseMetadata metadata{};
  CHECK(PWXrslamTransportGetPoseMetadata(&metadata) == PW_XRSLAM_OK);
  CHECK(metadata.transform_semantics == PW_XRSLAM_T_WORLD_CAMERA);
  CHECK(metadata.quaternion_order == PW_XRSLAM_QUATERNION_XYZW);

  double matrix[16]{};
  CHECK(PWXrslamTransportPoseToWorldFromCameraMatrix(&pose, matrix) ==
        PW_XRSLAM_OK);
  const double expected[16] = {
      0.0, -1.0, 0.0, 1.0, 1.0, 0.0, 0.0, 2.0,
      0.0, 0.0,  1.0, 3.0, 0.0, 0.0, 0.0, 1.0,
  };
  for (int i = 0; i < 16; ++i)
    CHECK(Near(matrix[i], expected[i], 1e-12));

  pose.quaternion[3] = 0.0;
  pose.quaternion[2] = 0.0;
  CHECK(PWXrslamTransportPoseToWorldFromCameraMatrix(&pose, matrix) ==
        PW_XRSLAM_ERR_INVALID_POSE);
  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
}

} // namespace

int main() {
  TestOffsetAppliedExactlyOnceAndOneRunPerCamera();
  TestPreparesExactBoxDownsampleIntoCallerPool();
  TestNegativeOffsetAppliedExactlyOnce();
  TestRejectsNonFiniteRollbackAndStoppedBeforeAbi();
  TestCreateFailureDoesNotOpenRunningGate();
  TestSuccessfulRecreateStartsANewTimestampGeneration();
  TestDestroyIsABarrierForAnInFlightCameraRun();
  TestWorldFromCameraXyzwGolden();
  std::cout << "pw_xrslam_transport_core_test: PASS\n";
  return 0;
}
