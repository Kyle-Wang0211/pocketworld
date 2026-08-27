#ifndef POCKETWORLD_XRSLAM_TRANSPORT_TESTS_FAKE_XRSLAM_H_
#define POCKETWORLD_XRSLAM_TRANSPORT_TESTS_FAKE_XRSLAM_H_

#include "XRSLAM.h"

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
};

extern FakeXrslamCalls g_fake_calls;
extern int g_fake_create_result;
extern XRSLAMState g_fake_state;
extern XRSLAMPose g_fake_pose;

void FakeXrslamReset();
void FakeXrslamBlockRun();
void FakeXrslamWaitForRunEntry();
void FakeXrslamReleaseRun();
bool FakeXrslamDestroyObservedCompletedRun();

#endif
