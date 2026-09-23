#include "PwXrslamTransportCore.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

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

// ── Per-frame intrinsics ──────────────────────────────────────────────────

// What the pre-change transport (cfe7d44 PwXrslamTransportCore.cpp:211-217)
// handed the core: a zeroed XRSLAMImage with ext == NULL. Built with memset so
// the padding / ext_size bytes are zero regardless of how `{}` treats padding.
XRSLAMImage LegacyImage(uint8_t *data, double timestamp, int32_t stride,
                        int32_t camera_id, int32_t channel) {
  XRSLAMImage image;
  std::memset(&image, 0, sizeof(image));
  image.data = data;
  image.timeStamp = timestamp;
  image.stride = stride;
  image.camera_id = camera_id;
  image.channel = channel;
  image.ext = nullptr;
  return image;
}

const std::vector<int> kLegacyCameraSequence = {
    kFakeCallPushCamera, kFakeCallRun, kFakeCallGetState,
    kFakeCallGetCameraPose};

void TestNullIntrinsicsIsTheLegacyPushByteForByte() {
  for (int variant = 0; variant < 2; ++variant) {
    FakeXrslamReset();
    CHECK(PWXrslamTransportCreateWithCameraTimeOffset("slam", "device",
                                                      0.125) == 1);
    std::array<uint8_t, 64> pixels{};
    int32_t state = -1;
    PWXrslamRawPose pose{};
    g_fake_calls.sequence.clear();
    const int32_t rc =
        variant == 0
            ? PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 10.0, 8, 0,
                                                   4, &state, &pose)
            : PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
                  pixels.data(), 10.0, 8, 0, 4, nullptr, &state, &pose);
    CHECK(rc == PW_XRSLAM_OK);
    const XRSLAMImage expected = LegacyImage(pixels.data(), 10.125, 8, 0, 4);
    CHECK(std::memcmp(g_fake_calls.last_image_bytes, &expected,
                      sizeof(XRSLAMImage)) == 0);
    XRSLAMImage seen;
    std::memcpy(&seen, g_fake_calls.last_image_bytes, sizeof(seen));
    CHECK(seen.ext == nullptr);
    CHECK(seen.ext_size == 0u);
    CHECK(!g_fake_calls.last_ext_present);
    // No XRSLAM_INFO_INTRINSICS query, nothing but the legacy four calls.
    CHECK(g_fake_calls.sequence == kLegacyCameraSequence);

    PWXrslamIntrinsicsTrace trace{};
    CHECK(PWXrslamTransportGetIntrinsicsTrace(&trace) == PW_XRSLAM_OK);
    CHECK(trace.camera_submitted_sequence == 1);
    CHECK(trace.last_per_frame_attached == 0);
    CHECK(trace.last_engine_report_read == 0);
    CHECK(trace.attached == 0);
    CHECK(trace.not_attached == 1);
    CHECK(trace.rejected_invalid == 0);
    CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
  }
}

void TestPerFrameIntrinsicsAttachExact72ByteExtension() {
  FakeXrslamReset();
  g_fake_intrinsics_mode = kFakeIntrinsicsForkLatest;
  CHECK(PWXrslamTransportCreateWithCameraTimeOffset("slam", "device", 0.0) ==
        1);
  std::array<uint8_t, 64> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  // Row 1 of run-6e2d4b99 intrinsics.jsonl (float32 values widened to double).
  const double k[4] = {1347.7943115234375, 1347.7943115234375,
                       957.4692993164062, 718.9641723632812};
  g_fake_calls.sequence.clear();
  CHECK(PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
            pixels.data(), 1.0, 8, 0, 4, k, &state, &pose) == PW_XRSLAM_OK);

  XRSLAMImage seen;
  std::memcpy(&seen, g_fake_calls.last_image_bytes, sizeof(seen));
  CHECK(seen.data == pixels.data());
  CHECK(seen.timeStamp == 1.0);
  CHECK(seen.stride == 8 && seen.camera_id == 0 && seen.channel == 4);
  CHECK(seen.ext_size == 72u);
  CHECK(seen.ext_size == sizeof(XRSLAMImageExtension));
  CHECK(seen.ext != nullptr);
  CHECK(g_fake_calls.last_ext_present);
  CHECK(g_fake_calls.last_ext_copied == 72u);

  // Upstream 32-byte prefix: all zero, as for a caller that sets nothing.
  for (std::size_t i = 0; i < XRSLAM_IMAGE_EXTENSION_LEGACY_SIZE; ++i)
    CHECK(g_fake_calls.last_ext_bytes[i] == 0);
  XRSLAMImageExtension ext;
  std::memcpy(&ext, g_fake_calls.last_ext_bytes, sizeof(ext));
  for (int i = 0; i < 4; ++i)
    CHECK(std::memcmp(&ext.intrinsics_fxfycxcy[i], &k[i], sizeof(double)) ==
          0);
  CHECK(ext.has_intrinsics == 1);
  CHECK(ext.reserved_pad == 0);
  CHECK(offsetof(XRSLAMImageExtension, intrinsics_fxfycxcy) == 32);
  CHECK(offsetof(XRSLAMImageExtension, has_intrinsics) == 64);
  CHECK(offsetof(XRSLAMImageExtension, reserved_pad) == 68);

  const std::vector<int> expected_sequence = {
      kFakeCallPushCamera, kFakeCallRun, kFakeCallGetState,
      kFakeCallGetCameraPose, kFakeCallGetIntrinsics};
  CHECK(g_fake_calls.sequence == expected_sequence);

  PWXrslamIntrinsicsTrace trace{};
  CHECK(PWXrslamTransportGetIntrinsicsTrace(&trace) == PW_XRSLAM_OK);
  CHECK(trace.camera_submitted_sequence == 1);
  CHECK(trace.last_per_frame_attached == 1);
  CHECK(trace.last_engine_report_read == 1);
  CHECK(trace.last_engine_report_matches == 1);
  for (int i = 0; i < 4; ++i) {
    CHECK(trace.last_attached_fxfycxcy[i] == k[i]);
    CHECK(trace.last_engine_fxfycxcy[i] == k[i]);
  }
  CHECK(trace.attached == 1 && trace.not_attached == 0);
  CHECK(trace.engine_report_matched == 1);

  // A legacy push in the same session: no extension, trace says so.
  g_fake_calls.sequence.clear();
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 2.0, 8, 0, 4,
                                             &state, &pose) == PW_XRSLAM_OK);
  CHECK(g_fake_calls.sequence == kLegacyCameraSequence);
  CHECK(!g_fake_calls.last_ext_present);
  CHECK(PWXrslamTransportGetIntrinsicsTrace(&trace) == PW_XRSLAM_OK);
  CHECK(trace.camera_submitted_sequence == 2);
  CHECK(trace.last_per_frame_attached == 0);
  CHECK(trace.attached == 1 && trace.not_attached == 1);

  // Create resets the session ledger.
  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  CHECK(PWXrslamTransportGetIntrinsicsTrace(&trace) == PW_XRSLAM_OK);
  CHECK(trace.attached == 0 && trace.not_attached == 0 &&
        trace.camera_submitted_sequence == 0);
  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
  CHECK(PWXrslamTransportGetIntrinsicsTrace(nullptr) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
}

void TestUpstreamCoreReportIsVisibleAsNotConsumed() {
  // A core without the fork change answers XRSLAM_INFO_INTRINSICS with its
  // config K; the trace must expose that the per-frame K was not taken.
  FakeXrslamReset();
  g_fake_intrinsics_mode = kFakeIntrinsicsConfigOnly;
  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  std::array<uint8_t, 64> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  const double k[4] = {1280.0, 1280.0, 957.5, 719.0};
  CHECK(PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
            pixels.data(), 1.0, 8, 0, 4, k, &state, &pose) == PW_XRSLAM_OK);
  PWXrslamIntrinsicsTrace trace{};
  CHECK(PWXrslamTransportGetIntrinsicsTrace(&trace) == PW_XRSLAM_OK);
  CHECK(trace.last_per_frame_attached == 1);
  CHECK(trace.last_engine_report_read == 1);
  CHECK(trace.last_engine_report_matches == 0);
  CHECK(trace.last_engine_fxfycxcy[0] == 1000.0);
  CHECK(trace.engine_report_matched == 0);
  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
}

void TestUnattachableIntrinsicsFallBackToLegacyPush() {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double inf = std::numeric_limits<double>::infinity();
  const double bad[][4] = {
      {nan, 1280.0, 957.5, 719.0}, {1280.0, 1280.0, inf, 719.0},
      {0.0, 1280.0, 957.5, 719.0}, {1280.0, -1.0, 957.5, 719.0},
  };
  FakeXrslamReset();
  g_fake_intrinsics_mode = kFakeIntrinsicsForkLatest;
  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  std::array<uint8_t, 64> pixels{};
  int32_t state = -1;
  PWXrslamRawPose pose{};
  double t = 1.0;
  for (const auto &k : bad) {
    g_fake_calls.sequence.clear();
    CHECK(PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
              pixels.data(), t, 8, 0, 4, k, &state, &pose) == PW_XRSLAM_OK);
    const XRSLAMImage expected = LegacyImage(pixels.data(), t, 8, 0, 4);
    CHECK(std::memcmp(g_fake_calls.last_image_bytes, &expected,
                      sizeof(XRSLAMImage)) == 0);
    CHECK(g_fake_calls.sequence == kLegacyCameraSequence);
    t += 1.0;
  }
  PWXrslamIntrinsicsTrace trace{};
  CHECK(PWXrslamTransportGetIntrinsicsTrace(&trace) == PW_XRSLAM_OK);
  CHECK(trace.attached == 0);
  CHECK(trace.not_attached == 4);
  CHECK(trace.rejected_invalid == 4);
  CHECK(trace.last_per_frame_attached == 0);
  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
}

void TestScaleIntrinsicsForBoxNxN() {
  // Hand-checked against pwvi_to_euroc.py:224-226 with d = 3.
  const double k[4] = {1347.7943115234375, 1347.7943115234375,
                       957.4692993164062, 718.9641723632812};
  double out[4] = {-7, -7, -7, -7};
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(k, 3, out) == PW_XRSLAM_OK);
  CHECK(out[0] == 1347.7943115234375 / 3.0);
  CHECK(out[1] == 1347.7943115234375 / 3.0);
  CHECK(out[2] == (957.4692993164062 + 0.5) / 3.0 - 0.5);
  CHECK(out[3] == (718.9641723632812 + 0.5) / 3.0 - 0.5);
  // Pixel-center convention: the center of source pixel 1 (block 0..2) maps
  // to the center of output pixel 0.
  const double center[4] = {3.0, 3.0, 1.0, 4.0};
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(center, 3, out) ==
        PW_XRSLAM_OK);
  CHECK(out[0] == 1.0 && out[2] == 0.0 && out[3] == 1.0);
  // factor 1 is the identity for these values.
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(k, 1, out) == PW_XRSLAM_OK);
  for (int i = 0; i < 4; ++i)
    CHECK(out[i] == k[i]);
  // Invalid arguments leave the destination untouched.
  double keep[4] = {9, 9, 9, 9};
  const double nan_k[4] = {std::numeric_limits<double>::quiet_NaN(), 1, 1, 1};
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(k, 0, keep) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(k, -3, keep) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(nan_k, 3, keep) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(nullptr, 3, keep) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
  CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(k, 3, nullptr) ==
        PW_XRSLAM_ERR_INVALID_ARGUMENT);
  for (double v : keep)
    CHECK(v == 9.0);
}

// Every row of a fixture produced by the real offline converter
// (see tests/make_rescale_fixture.py). Columns:
//   t_ns, raw fx, fy, cx, cy (intrinsics.jsonl), factor,
//   converter fx, fy, cx, cy (its --intrinsics-csv output, repr() round-trip)
int TestScaleMatchesOfflineConverterFixture(const char *path) {
  std::ifstream in(path);
  CHECK(in.good());
  std::string line;
  int rows = 0;
  double max_abs = 0.0;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#')
      continue;
    std::stringstream ss(line);
    std::string cell;
    std::vector<std::string> cells;
    while (std::getline(ss, cell, ','))
      cells.push_back(cell);
    CHECK(cells.size() == 10);
    double raw[4];
    double expected[4];
    for (int i = 0; i < 4; ++i) {
      raw[i] = std::stod(cells[1 + i]);
      expected[i] = std::stod(cells[6 + i]);
    }
    const int32_t factor = static_cast<int32_t>(std::stol(cells[5]));
    double got[4];
    CHECK(PWXrslamTransportScaleIntrinsicsForBoxNxN(raw, factor, got) ==
          PW_XRSLAM_OK);
    for (int i = 0; i < 4; ++i) {
      const double diff = std::abs(got[i] - expected[i]);
      if (diff > max_abs)
        max_abs = diff;
      CHECK(diff <= 1e-9);
    }
    ++rows;
  }
  CHECK(rows > 0);
  std::cout << "offline converter fixture: rows=" << rows
            << " max_abs_diff=" << max_abs << '\n';
  return rows;
}

} // namespace

int main(int argc, char **argv) {
  TestOffsetAppliedExactlyOnceAndOneRunPerCamera();
  TestPreparesExactBoxDownsampleIntoCallerPool();
  TestNegativeOffsetAppliedExactlyOnce();
  TestRejectsNonFiniteRollbackAndStoppedBeforeAbi();
  TestCreateFailureDoesNotOpenRunningGate();
  TestSuccessfulRecreateStartsANewTimestampGeneration();
  TestDestroyIsABarrierForAnInFlightCameraRun();
  TestWorldFromCameraXyzwGolden();
  TestNullIntrinsicsIsTheLegacyPushByteForByte();
  TestPerFrameIntrinsicsAttachExact72ByteExtension();
  TestUpstreamCoreReportIsVisibleAsNotConsumed();
  TestUnattachableIntrinsicsFallBackToLegacyPush();
  TestScaleIntrinsicsForBoxNxN();
  if (argc > 1)
    TestScaleMatchesOfflineConverterFixture(argv[1]);
  std::cout << "pw_xrslam_transport_core_test: PASS\n";
  return 0;
}
