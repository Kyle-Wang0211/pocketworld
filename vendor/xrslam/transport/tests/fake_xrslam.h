#ifndef POCKETWORLD_XRSLAM_TRANSPORT_TESTS_FAKE_XRSLAM_H_
#define POCKETWORLD_XRSLAM_TRANSPORT_TESTS_FAKE_XRSLAM_H_

#include "XRSLAM.h"

#include <cstdint>
#include <vector>

// Order of official ABI calls, recorded so a test can assert that a push with
// no per-frame intrinsics issues exactly the legacy call sequence.
enum FakeXrslamCall : int {
  kFakeCallPushCamera = 1,
  kFakeCallPushAcceleration,
  kFakeCallPushGyroscope,
  kFakeCallRun,
  kFakeCallGetState,
  kFakeCallGetCameraPose,
  kFakeCallGetIntrinsics,
  kFakeCallGetOther,
};

struct FakeXrslamCalls {
  int create = 0;
  int destroy = 0;
  int camera_push = 0;
  int acceleration_push = 0;
  int gyroscope_push = 0;
  int run = 0;
  int get_result = 0;
  double last_camera_timestamp = 0.0;
  double last_acceleration_timestamp = 0.0;
  double last_gyroscope_timestamp = 0.0;
  // Byte copy of the last XRSLAMImage handed to XRSLAMPushSensorData, and of
  // its extension when ext != NULL (copied with the size the engine would
  // read: ext_size when it equals the v2 size, else the legacy 32 bytes).
  unsigned char last_image_bytes[sizeof(XRSLAMImage)] = {};
  bool last_ext_present = false;
  unsigned int last_ext_copied = 0;
  unsigned char last_ext_bytes[sizeof(XRSLAMImageExtension)] = {};
  std::vector<int> sequence;
};

// How the fake answers XRSLAM_INFO_INTRINSICS:
//   kFakeIntrinsicsConfigOnly  = unmodified upstream core: always the config K.
//   kFakeIntrinsicsForkLatest  = fork 04c0e83: latest valid per-frame K if one
//                                was pushed this session, else the config K.
enum FakeIntrinsicsMode : int {
  kFakeIntrinsicsConfigOnly = 0,
  kFakeIntrinsicsForkLatest = 1,
};

extern FakeXrslamCalls g_fake_calls;
extern int g_fake_create_result;
extern XRSLAMState g_fake_state;
extern XRSLAMPose g_fake_pose;
extern XRSLAMIntrinsics g_fake_config_intrinsics;
extern FakeIntrinsicsMode g_fake_intrinsics_mode;

void FakeXrslamReset();
void FakeXrslamBlockRun();
void FakeXrslamWaitForRunEntry();
void FakeXrslamReleaseRun();
bool FakeXrslamDestroyObservedCompletedRun();

#endif
