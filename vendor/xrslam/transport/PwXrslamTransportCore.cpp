#include "PwXrslamTransportCore.h"

#include <cmath>
#include <cstddef>
#include <mutex>

#include "XRSLAM.h"

// Layout of the per-frame intrinsics extension, copied from fork commit
// 04c0e83 xrslam-interface/src/XRSLAMImageExt.h:25-44 (the engine side of the
// same contract). If the mirror header drifts from the engine, this fails to
// compile instead of silently handing the engine a mis-laid-out struct.
static_assert(sizeof(void *) == 8,
              "ext_size sits in the existing padding only under LP64");
static_assert(sizeof(XRSLAMImage) == 40, "XRSLAMImage must stay 40 bytes");
static_assert(offsetof(XRSLAMImage, data) == 0 &&
                  offsetof(XRSLAMImage, timeStamp) == 8 &&
                  offsetof(XRSLAMImage, stride) == 16 &&
                  offsetof(XRSLAMImage, camera_id) == 20 &&
                  offsetof(XRSLAMImage, channel) == 24 &&
                  offsetof(XRSLAMImage, ext) == 32,
              "upstream XRSLAMImage member offsets moved");
static_assert(offsetof(XRSLAMImage, ext_size) == 28 &&
                  sizeof(XRSLAMImage::ext_size) == 4,
              "ext_size must occupy the 4-byte padding between channel and ext");
static_assert(offsetof(XRSLAMImageExtension, exposure_time) == 0 &&
                  offsetof(XRSLAMImageExtension, default_focus_distance) == 8 &&
                  offsetof(XRSLAMImageExtension, focal_length) == 16 &&
                  offsetof(XRSLAMImageExtension, focus_distance) == 24,
              "upstream XRSLAMImageExtension prefix moved");
static_assert(offsetof(XRSLAMImageExtension, intrinsics_fxfycxcy) ==
                  XRSLAM_IMAGE_EXTENSION_LEGACY_SIZE,
              "intrinsics must follow the upstream 32-byte prefix");
static_assert(sizeof(XRSLAMImageExtension) == 72,
              "XRSLAMImageExtension v2 is 72 bytes (fork 04c0e83)");

namespace {

std::mutex g_core_mutex;

struct StreamState {
  bool has_submitted_timestamp = false;
  double last_submitted_timestamp = 0.0;
  PWXrslamTimestampTrace trace{};
};

struct SessionCounters {
  uint64_t camera_submitted = 0;
  uint64_t camera_run_calls = 0;
  uint64_t acceleration_submitted = 0;
  uint64_t gyroscope_submitted = 0;
  uint64_t rejected_invalid_argument = 0;
  uint64_t rejected_non_monotonic = 0;
  uint64_t rejected_not_running = 0;
};

bool g_running = false;
double g_camera_time_offset_seconds = 0.0;
uint64_t g_lifecycle_generation = 0;
StreamState g_streams[3];
SessionCounters g_counters;
PWXrslamIntrinsicsTrace g_intrinsics_trace{};

// The same acceptance rule the fork engine applies before it uses a per-frame
// K (fork 04c0e83 xrslam-interface/src/XRSLAMImageExt.h:57-62): all four
// finite, fx > 0, fy > 0. Anything else would be ignored by the engine, so the
// transport does not attach it and counts it instead.
bool IsAttachableIntrinsics(const double *k) {
  for (int i = 0; i < 4; ++i) {
    if (!std::isfinite(k[i]))
      return false;
  }
  return k[0] > 0.0 && k[1] > 0.0;
}

bool IsFinite3(double x, double y, double z) {
  return std::isfinite(x) && std::isfinite(y) && std::isfinite(z);
}

bool IsValidStream(int32_t stream) {
  return stream >= PW_XRSLAM_STREAM_CAMERA &&
         stream <= PW_XRSLAM_STREAM_GYROSCOPE;
}

void ResetSessionState() {
  for (StreamState &stream : g_streams)
    stream = {};
  g_counters = {};
  g_intrinsics_trace = {};
}

void FillDestroyReceipt(bool acknowledged, PWXrslamDestroyReceipt *receipt) {
  if (receipt == nullptr)
    return;
  *receipt = {};
  receipt->lifecycle_generation = g_lifecycle_generation;
  receipt->camera_submitted = g_counters.camera_submitted;
  receipt->camera_run_calls = g_counters.camera_run_calls;
  receipt->acceleration_submitted = g_counters.acceleration_submitted;
  receipt->gyroscope_submitted = g_counters.gyroscope_submitted;
  receipt->rejected_invalid_argument = g_counters.rejected_invalid_argument;
  receipt->rejected_non_monotonic = g_counters.rejected_non_monotonic;
  receipt->rejected_not_running = g_counters.rejected_not_running;
  receipt->destroy_acknowledged = acknowledged ? 1 : 0;
}

void FillCounters(PWXrslamTransportCounters *counters) {
  if (counters == nullptr)
    return;
  *counters = {};
  counters->lifecycle_generation = g_lifecycle_generation;
  counters->camera_submitted = g_counters.camera_submitted;
  counters->camera_run_calls = g_counters.camera_run_calls;
  counters->acceleration_submitted = g_counters.acceleration_submitted;
  counters->gyroscope_submitted = g_counters.gyroscope_submitted;
  counters->rejected_invalid_argument = g_counters.rejected_invalid_argument;
  counters->rejected_non_monotonic = g_counters.rejected_non_monotonic;
  counters->rejected_not_running = g_counters.rejected_not_running;
  counters->running = g_running ? 1 : 0;
}

void RecordTrace(int32_t stream, int32_t status, double raw_timestamp,
                 double offset, double effective_timestamp) {
  StreamState &state = g_streams[stream];
  state.trace.stream = stream;
  state.trace.status = status;
  state.trace.raw_timestamp = raw_timestamp;
  state.trace.applied_offset = offset;
  state.trace.effective_timestamp = effective_timestamp;
}

int32_t ValidateTimestampLocked(int32_t stream, double raw_timestamp,
                                double offset, double *effective_timestamp) {
  if (!g_running) {
    ++g_counters.rejected_not_running;
    if (std::isfinite(raw_timestamp) && std::isfinite(offset)) {
      RecordTrace(stream, PW_XRSLAM_ERR_NOT_RUNNING, raw_timestamp, offset,
                  raw_timestamp + offset);
    }
    return PW_XRSLAM_ERR_NOT_RUNNING;
  }
  if (!std::isfinite(raw_timestamp) || !std::isfinite(offset)) {
    ++g_counters.rejected_invalid_argument;
    RecordTrace(stream, PW_XRSLAM_ERR_INVALID_ARGUMENT, raw_timestamp, offset,
                raw_timestamp);
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  const double effective = raw_timestamp + offset;
  if (!std::isfinite(effective)) {
    ++g_counters.rejected_invalid_argument;
    RecordTrace(stream, PW_XRSLAM_ERR_INVALID_ARGUMENT, raw_timestamp, offset,
                effective);
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  StreamState &state = g_streams[stream];
  if (state.has_submitted_timestamp &&
      effective <= state.last_submitted_timestamp) {
    ++g_counters.rejected_non_monotonic;
    RecordTrace(stream, PW_XRSLAM_ERR_NON_MONOTONIC, raw_timestamp, offset,
                effective);
    return PW_XRSLAM_ERR_NON_MONOTONIC;
  }
  *effective_timestamp = effective;
  return PW_XRSLAM_OK;
}

void MarkSubmittedLocked(int32_t stream, double raw_timestamp, double offset,
                         double effective_timestamp) {
  StreamState &state = g_streams[stream];
  state.has_submitted_timestamp = true;
  state.last_submitted_timestamp = effective_timestamp;
  ++state.trace.submitted_sequence;
  RecordTrace(stream, PW_XRSLAM_OK, raw_timestamp, offset, effective_timestamp);
}

void CopyRawPose(const XRSLAMPose &source, PWXrslamRawPose *destination) {
  if (destination == nullptr)
    return;
  destination->timestamp = source.timestamp;
  for (int i = 0; i < 4; ++i) {
    destination->quaternion[i] = source.quaternion[i];
  }
  for (int i = 0; i < 3; ++i) {
    destination->translation[i] = source.translation[i];
  }
}

} // namespace

extern "C" int32_t PWXrslamTransportCreate(const char *slam_config_path,
                                           const char *device_config_path) {
  return PWXrslamTransportCreateWithCameraTimeOffset(slam_config_path,
                                                     device_config_path, 0.0);
}

extern "C" int32_t
PWXrslamTransportCreateWithCameraTimeOffset(const char *slam_config_path,
                                            const char *device_config_path,
                                            double camera_time_offset_seconds) {
  if (slam_config_path == nullptr || device_config_path == nullptr ||
      !std::isfinite(camera_time_offset_seconds)) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(g_core_mutex);
  if (g_running)
    return 0;
  void *config = nullptr;
  const int32_t result = XRSLAMCreate(slam_config_path, device_config_path, "",
                                      "pocketworld", &config);
  if (result != 1)
    return 0;
  ++g_lifecycle_generation;
  ResetSessionState();
  g_camera_time_offset_seconds = camera_time_offset_seconds;
  g_running = true;
  return 1;
}

extern "C" void PWXrslamTransportDestroy(void) {
  (void)PWXrslamTransportDestroyWithReceipt(nullptr);
}

extern "C" int32_t
PWXrslamTransportDestroyWithReceipt(PWXrslamDestroyReceipt *receipt) {
  std::lock_guard<std::mutex> lock(g_core_mutex);
  if (!g_running) {
    ++g_counters.rejected_not_running;
    FillDestroyReceipt(false, receipt);
    return PW_XRSLAM_ERR_NOT_RUNNING;
  }
  XRSLAMDestroy();
  g_running = false;
  FillDestroyReceipt(true, receipt);
  return PW_XRSLAM_OK;
}

extern "C" int32_t PWXrslamTransportPushCameraAndRunRaw(
    uint8_t *data, double timestamp, int32_t stride, int32_t camera_id,
    int32_t channel, int32_t *raw_state, PWXrslamRawPose *raw_pose) {
  return PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
      data, timestamp, stride, camera_id, channel, nullptr, raw_state,
      raw_pose);
}

extern "C" int32_t PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
    uint8_t *data, double timestamp, int32_t stride, int32_t camera_id,
    int32_t channel, const double *k_fxfycxcy, int32_t *raw_state,
    PWXrslamRawPose *raw_pose) {
  std::lock_guard<std::mutex> lock(g_core_mutex);
  if (data == nullptr || stride <= 0 || channel <= 0 || raw_state == nullptr ||
      raw_pose == nullptr) {
    ++g_counters.rejected_invalid_argument;
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  double effective_timestamp = 0.0;
  const int32_t validation = ValidateTimestampLocked(
      PW_XRSLAM_STREAM_CAMERA, timestamp, g_camera_time_offset_seconds,
      &effective_timestamp);
  if (validation != PW_XRSLAM_OK)
    return validation;

  XRSLAMImage image{};
  image.data = data;
  image.timeStamp = effective_timestamp;
  image.stride = stride;
  image.camera_id = camera_id;
  image.channel = channel;
  image.ext = nullptr;

  // Per-frame K, fork 04c0e83 contract: the engine reads the appended fields
  // only when ext_size == sizeof(XRSLAMImageExtension) and has_intrinsics == 1
  // (XRSLAMImageExt.h:49-66). The upstream 32-byte prefix stays zero, the same
  // as upstream callers that pass no extension at all.
  // k_fxfycxcy == NULL leaves `image` exactly as the legacy push built it.
  XRSLAMImageExtension extension{};
  const bool attach =
      k_fxfycxcy != nullptr && IsAttachableIntrinsics(k_fxfycxcy);
  if (attach) {
    for (int i = 0; i < 4; ++i)
      extension.intrinsics_fxfycxcy[i] = k_fxfycxcy[i];
    extension.has_intrinsics = 1;
    extension.reserved_pad = 0;
    image.ext_size = static_cast<unsigned int>(sizeof(XRSLAMImageExtension));
    image.ext = &extension;
  }

  XRSLAMPushSensorData(XRSLAM_SENSOR_CAMERA, &image);
  MarkSubmittedLocked(PW_XRSLAM_STREAM_CAMERA, timestamp,
                      g_camera_time_offset_seconds, effective_timestamp);
  ++g_counters.camera_submitted;
  XRSLAMRunOneFrame();
  ++g_counters.camera_run_calls;

  XRSLAMState state = XRSLAM_STATE_INITIALIZING;
  XRSLAMPose pose{};
  XRSLAMGetResult(XRSLAM_RESULT_STATE, &state);
  XRSLAMGetResult(XRSLAM_RESULT_CAMERA_POSE, &pose);
  *raw_state = static_cast<int32_t>(state);
  CopyRawPose(pose, raw_pose);

  PWXrslamIntrinsicsTrace &trace = g_intrinsics_trace;
  trace.camera_submitted_sequence =
      g_streams[PW_XRSLAM_STREAM_CAMERA].trace.submitted_sequence;
  trace.last_per_frame_attached = attach ? 1 : 0;
  trace.last_engine_report_read = 0;
  trace.last_engine_report_matches = 0;
  for (int i = 0; i < 4; ++i) {
    trace.last_attached_fxfycxcy[i] = attach ? k_fxfycxcy[i] : 0.0;
    trace.last_engine_fxfycxcy[i] = 0.0;
  }
  if (attach) {
    ++trace.attached;
    // Read-only query that both the upstream core (config K) and the fork
    // core (latest per-frame K, fork XRSLAMManager.cpp:348-362) answer.
    // Only issued when a K was attached, so the legacy call sequence is
    // unchanged.
    XRSLAMIntrinsics reported{};
    XRSLAMGetResult(XRSLAM_INFO_INTRINSICS, &reported);
    trace.last_engine_report_read = 1;
    trace.last_engine_fxfycxcy[0] = reported.fx;
    trace.last_engine_fxfycxcy[1] = reported.fy;
    trace.last_engine_fxfycxcy[2] = reported.cx;
    trace.last_engine_fxfycxcy[3] = reported.cy;
    const bool matches = reported.fx == k_fxfycxcy[0] &&
                         reported.fy == k_fxfycxcy[1] &&
                         reported.cx == k_fxfycxcy[2] &&
                         reported.cy == k_fxfycxcy[3];
    trace.last_engine_report_matches = matches ? 1 : 0;
    if (matches)
      ++trace.engine_report_matched;
  } else {
    ++trace.not_attached;
    if (k_fxfycxcy != nullptr)
      ++trace.rejected_invalid;
  }
  return PW_XRSLAM_OK;
}

extern "C" int32_t
PWXrslamTransportGetIntrinsicsTrace(PWXrslamIntrinsicsTrace *trace) {
  if (trace == nullptr)
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(g_core_mutex);
  *trace = g_intrinsics_trace;
  return PW_XRSLAM_OK;
}

extern "C" int32_t PWXrslamTransportScaleIntrinsicsForBoxNxN(
    const double source[4], int32_t factor, double destination[4]) {
  if (source == nullptr || destination == nullptr || factor <= 0)
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  for (int i = 0; i < 4; ++i) {
    if (!std::isfinite(source[i]))
      return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  // arloopbench tools/pwvi_to_euroc.py:224-226, same operations in the same
  // order (IEEE double; no multiply-add to contract):
  //   fx, fy, cx, cy = (K[0] / d, K[1] / d, (K[2] + 0.5) / d - 0.5,
  //                     (K[3] + 0.5) / d - 0.5)
  const double d = static_cast<double>(factor);
  destination[0] = source[0] / d;
  destination[1] = source[1] / d;
  destination[2] = (source[2] + 0.5) / d - 0.5;
  destination[3] = (source[3] + 0.5) / d - 0.5;
  return PW_XRSLAM_OK;
}

extern "C" int32_t PWXrslamTransportPushAccelerationRaw(double timestamp,
                                                        double x, double y,
                                                        double z) {
  std::lock_guard<std::mutex> lock(g_core_mutex);
  if (!IsFinite3(x, y, z)) {
    ++g_counters.rejected_invalid_argument;
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  double effective_timestamp = 0.0;
  const int32_t validation = ValidateTimestampLocked(
      PW_XRSLAM_STREAM_ACCELERATION, timestamp, 0.0, &effective_timestamp);
  if (validation != PW_XRSLAM_OK)
    return validation;
  XRSLAMAcceleration sample{{x, y, z}, effective_timestamp};
  XRSLAMPushSensorData(XRSLAM_SENSOR_ACCELERATION, &sample);
  MarkSubmittedLocked(PW_XRSLAM_STREAM_ACCELERATION, timestamp, 0.0,
                      effective_timestamp);
  ++g_counters.acceleration_submitted;
  return PW_XRSLAM_OK;
}

extern "C" int32_t PWXrslamTransportPushGyroscopeRaw(double timestamp, double x,
                                                     double y, double z) {
  std::lock_guard<std::mutex> lock(g_core_mutex);
  if (!IsFinite3(x, y, z)) {
    ++g_counters.rejected_invalid_argument;
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  double effective_timestamp = 0.0;
  const int32_t validation = ValidateTimestampLocked(
      PW_XRSLAM_STREAM_GYROSCOPE, timestamp, 0.0, &effective_timestamp);
  if (validation != PW_XRSLAM_OK)
    return validation;
  XRSLAMGyroscope sample{{x, y, z}, effective_timestamp};
  XRSLAMPushSensorData(XRSLAM_SENSOR_GYROSCOPE, &sample);
  MarkSubmittedLocked(PW_XRSLAM_STREAM_GYROSCOPE, timestamp, 0.0,
                      effective_timestamp);
  ++g_counters.gyroscope_submitted;
  return PW_XRSLAM_OK;
}

extern "C" int32_t
PWXrslamTransportGetLastTimestampTrace(int32_t stream,
                                       PWXrslamTimestampTrace *trace) {
  if (!IsValidStream(stream) || trace == nullptr) {
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(g_core_mutex);
  *trace = g_streams[stream].trace;
  trace->stream = stream;
  return PW_XRSLAM_OK;
}

extern "C" int32_t
PWXrslamTransportGetPoseMetadata(PWXrslamPoseMetadata *metadata) {
  if (metadata == nullptr)
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  metadata->transform_semantics = PW_XRSLAM_T_WORLD_CAMERA;
  metadata->quaternion_order = PW_XRSLAM_QUATERNION_XYZW;
  return PW_XRSLAM_OK;
}

extern "C" int32_t
PWXrslamTransportGetCounters(PWXrslamTransportCounters *counters) {
  if (counters == nullptr)
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(g_core_mutex);
  FillCounters(counters);
  return PW_XRSLAM_OK;
}

extern "C" int32_t PWXrslamTransportPrepareGrayBoxNxN(
    const uint8_t *source, int32_t source_width, int32_t source_height,
    int32_t source_stride, int32_t factor, uint8_t *destination,
    int32_t destination_capacity, int32_t *destination_width,
    int32_t *destination_height) {
  if (source == nullptr || destination == nullptr ||
      destination_width == nullptr || destination_height == nullptr ||
      source_width <= 0 || source_height <= 0 ||
      source_stride < source_width || factor <= 0 ||
      source_width % factor != 0 || source_height % factor != 0) {
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  const int32_t output_width = source_width / factor;
  const int32_t output_height = source_height / factor;
  const int64_t output_size =
      static_cast<int64_t>(output_width) * output_height;
  if (output_size <= 0 || output_size > destination_capacity) {
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  const int32_t area = factor * factor;
  const int32_t half = area / 2;
  for (int32_t y = 0; y < output_height; ++y) {
    uint8_t *output_row = destination + y * output_width;
    for (int32_t x = 0; x < output_width; ++x) {
      int32_t sum = 0;
      for (int32_t dy = 0; dy < factor; ++dy) {
        const uint8_t *input = source +
            (y * factor + dy) * source_stride + x * factor;
        for (int32_t dx = 0; dx < factor; ++dx)
          sum += input[dx];
      }
      output_row[x] = static_cast<uint8_t>((sum + half) / area);
    }
  }
  *destination_width = output_width;
  *destination_height = output_height;
  return PW_XRSLAM_OK;
}

extern "C" int32_t
PWXrslamTransportPoseToWorldFromCameraMatrix(const PWXrslamRawPose *pose,
                                             double matrix[16]) {
  if (pose == nullptr || matrix == nullptr ||
      !IsFinite3(pose->translation[0], pose->translation[1],
                 pose->translation[2]) ||
      !std::isfinite(pose->timestamp)) {
    return PW_XRSLAM_ERR_INVALID_ARGUMENT;
  }
  const double x = pose->quaternion[0];
  const double y = pose->quaternion[1];
  const double z = pose->quaternion[2];
  const double w = pose->quaternion[3];
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) ||
      !std::isfinite(w)) {
    return PW_XRSLAM_ERR_INVALID_POSE;
  }
  const double norm_squared = x * x + y * y + z * z + w * w;
  if (!std::isfinite(norm_squared) || norm_squared <= 1e-24) {
    return PW_XRSLAM_ERR_INVALID_POSE;
  }
  const double inverse_norm = 1.0 / std::sqrt(norm_squared);
  const double qx = x * inverse_norm;
  const double qy = y * inverse_norm;
  const double qz = z * inverse_norm;
  const double qw = w * inverse_norm;

  matrix[0] = 1.0 - 2.0 * (qy * qy + qz * qz);
  matrix[1] = 2.0 * (qx * qy - qz * qw);
  matrix[2] = 2.0 * (qx * qz + qy * qw);
  matrix[3] = pose->translation[0];
  matrix[4] = 2.0 * (qx * qy + qz * qw);
  matrix[5] = 1.0 - 2.0 * (qx * qx + qz * qz);
  matrix[6] = 2.0 * (qy * qz - qx * qw);
  matrix[7] = pose->translation[1];
  matrix[8] = 2.0 * (qx * qz - qy * qw);
  matrix[9] = 2.0 * (qy * qz + qx * qw);
  matrix[10] = 1.0 - 2.0 * (qx * qx + qy * qy);
  matrix[11] = pose->translation[2];
  matrix[12] = 0.0;
  matrix[13] = 0.0;
  matrix[14] = 0.0;
  matrix[15] = 1.0;
  return PW_XRSLAM_OK;
}
