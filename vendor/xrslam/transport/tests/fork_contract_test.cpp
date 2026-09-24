// fork_contract_test.cpp — the shared transport against the fork engine's own
// consumption rule for per-frame intrinsics.
//
// The fork (github.com/Kyle-Wang0211/xrslam, commit 04c0e83) decides whether a
// pushed XRSLAMImage carries a usable per-frame K in the header-only
// xrslam::pw::take_frame_intrinsics (xrslam-interface/src/XRSLAMImageExt.h).
// This test compiles that exact header against the pocketworld mirror
// vendor/xrslam/include/XRSLAM.h — so the fork's layout static_asserts run
// against the mirror — and calls it from inside a stand-in
// XRSLAMPushSensorData on the struct the transport really pushed.
//
// Built only when PW_XRSLAM_FORK_SRC points at a fork tree (see CMakeLists.txt).
#include "PwXrslamTransportCore.h"

#include "XRSLAMImageExt.h"

#include <array>
#include <cstdlib>
#include <iostream>

namespace {
bool g_consumed = false;
double g_consumed_k[4] = {0, 0, 0, 0};
int g_pushes = 0;

void Check(bool condition, const char *expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression << '\n';
    std::exit(1);
  }
}
#define CHECK(expression) Check((expression), #expression, __LINE__)
} // namespace

extern "C" int XRSLAMCreate(const char *, const char *, const char *,
                            const char *, void **config) {
  if (config != nullptr)
    *config = config;
  return 1;
}
extern "C" void XRSLAMPushSensorData(XRSLAMSensorType type, void *data) {
  if (type != XRSLAM_SENSOR_CAMERA)
    return;
  ++g_pushes;
  g_consumed = xrslam::pw::take_frame_intrinsics(
      static_cast<const XRSLAMImage *>(data), g_consumed_k);
}
extern "C" void XRSLAMRunOneFrame() {}
extern "C" void XRSLAMGetResult(XRSLAMResultType type, void *result) {
  if (type == XRSLAM_RESULT_STATE)
    *static_cast<XRSLAMState *>(result) = XRSLAM_STATE_INITIALIZING;
  else if (type == XRSLAM_RESULT_CAMERA_POSE)
    *static_cast<XRSLAMPose *>(result) = XRSLAMPose{};
  else if (type == XRSLAM_INFO_INTRINSICS)
    *static_cast<XRSLAMIntrinsics *>(result) = XRSLAMIntrinsics{};
}
extern "C" void XRSLAMDestroy() {}

int main() {
  CHECK(PWXrslamTransportCreate("slam", "device") == 1);
  std::array<uint8_t, 64> pixels{};
  int32_t state = 0;
  PWXrslamRawPose pose{};

  // Legacy entry point: the fork must not see a per-frame K.
  CHECK(PWXrslamTransportPushCameraAndRunRaw(pixels.data(), 1.0, 8, 0, 4,
                                             &state, &pose) == PW_XRSLAM_OK);
  CHECK(g_pushes == 1 && !g_consumed);

  // NULL K through the new entry point: same.
  CHECK(PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
            pixels.data(), 2.0, 8, 0, 4, nullptr, &state, &pose) ==
        PW_XRSLAM_OK);
  CHECK(g_pushes == 2 && !g_consumed);

  // A real K: the fork's own rule accepts it and reads back the same bits.
  const double k[4] = {428.7291259765625, 428.7291259765625,
                       318.90126546223956, 239.3442586263021};
  CHECK(PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
            pixels.data(), 3.0, 8, 0, 4, k, &state, &pose) == PW_XRSLAM_OK);
  CHECK(g_pushes == 3 && g_consumed);
  for (int i = 0; i < 4; ++i)
    CHECK(g_consumed_k[i] == k[i]);

  CHECK(PWXrslamTransportDestroyWithReceipt(nullptr) == PW_XRSLAM_OK);
  std::cout << "pw_xrslam_fork_contract_test: PASS (fork take_frame_intrinsics "
               "accepts the transport's ext, rejects legacy/NULL pushes)\n";
  return 0;
}
