#include <jni.h>

#include "PwXrslamTransportCore.h"

namespace {
class UtfChars final {
 public:
  UtfChars(JNIEnv* env, jstring value)
      : env_(env), value_(value), chars_(env->GetStringUTFChars(value, nullptr)) {}
  ~UtfChars() {
    if (chars_ != nullptr) env_->ReleaseStringUTFChars(value_, chars_);
  }
  const char* get() const { return chars_; }

 private:
  JNIEnv* env_;
  jstring value_;
  const char* chars_;
};
}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativeCreate(
    JNIEnv* env, jobject, jstring slam_path, jstring device_path) {
  if (slam_path == nullptr || device_path == nullptr) return 0;
  UtfChars slam(env, slam_path);
  UtfChars device(env, device_path);
  if (slam.get() == nullptr || device.get() == nullptr) return 0;
  return PWXrslamTransportCreate(slam.get(), device.get());
}

extern "C" JNIEXPORT void JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativeDestroy(
    JNIEnv*, jobject) {
  PWXrslamTransportDestroy();
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativePushCameraAndRunRaw(
    JNIEnv* env, jobject, jobject buffer, jdouble timestamp, jint stride,
    jint camera_id, jint channel) {
  auto* data = static_cast<unsigned char*>(env->GetDirectBufferAddress(buffer));
  int32_t raw_state = 0;
  PWXrslamRawPose raw_pose{};
  const int32_t transport_rc = PWXrslamTransportPushCameraAndRunRaw(
      data, timestamp, stride, camera_id, channel, &raw_state, &raw_pose);
  const jdouble values[] = {
      static_cast<jdouble>(transport_rc),
      static_cast<jdouble>(raw_state),
      raw_pose.timestamp,
      raw_pose.quaternion[0],
      raw_pose.quaternion[1],
      raw_pose.quaternion[2],
      raw_pose.quaternion[3],
      raw_pose.translation[0],
      raw_pose.translation[1],
      raw_pose.translation[2],
  };
  jdoubleArray result = env->NewDoubleArray(10);
  if (result != nullptr) env->SetDoubleArrayRegion(result, 0, 10, values);
  return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativePushAcceleration(
    JNIEnv*, jobject, jdouble timestamp, jdouble x, jdouble y, jdouble z) {
  return PWXrslamTransportPushAccelerationRaw(timestamp, x, y, z);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativePushGyroscope(
    JNIEnv*, jobject, jdouble timestamp, jdouble x, jdouble y, jdouble z) {
  return PWXrslamTransportPushGyroscopeRaw(timestamp, x, y, z);
}

// ── [pw 2026-09-22] Android 喂料链接线补的三个入口 ────────────────────────
// 加这三个不是扩接口,是**把 iOS 已经在用的三个 C 入口暴露给 JNI**:
//   · PWXrslamTransportCreateWithCameraTimeOffset —— 每机常量 c(曝光中点换算
//     的不可查表部分)在传输层施加,iOS 侧 PwXrslamLive.swift:create 用的就是它。
//   · PWXrslamTransportGetLastTimestampTrace —— 时基运行期自证的唯一数据源,
//     iOS 侧 PwXrslamLive.swift:runOneFrame 推完当帧就读它。
//   · PWXrslamTransportGetCounters —— 账本。头文件原话 "Swift must not
//     synthesize them",对 Kotlin 同样成立:Kotlin 不得自己数。
// 三个都只做 marshalling,零判断。

extern "C" JNIEXPORT jint JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativeCreateWithCameraTimeOffset(
    JNIEnv* env, jobject, jstring slam_path, jstring device_path,
    jdouble camera_time_offset_seconds) {
  if (slam_path == nullptr || device_path == nullptr) return 0;
  UtfChars slam(env, slam_path);
  UtfChars device(env, device_path);
  if (slam.get() == nullptr || device.get() == nullptr) return 0;
  return PWXrslamTransportCreateWithCameraTimeOffset(
      slam.get(), device.get(), camera_time_offset_seconds);
}

// out[6] = {stream, status, raw_timestamp, applied_offset, effective_timestamp,
//           submitted_sequence}。
// 🔴 submitted_sequence 是 uint64,经 double 只精确到 2^53 —— 它是诊断序号,
//    不参与任何判定;精确计数走 nativeGetCounters 的 jlong 路径。
extern "C" JNIEXPORT jint JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativeGetLastTimestampTrace(
    JNIEnv* env, jobject, jint stream, jdoubleArray out) {
  if (out == nullptr || env->GetArrayLength(out) < 6) return -1;
  PWXrslamTimestampTrace trace{};
  const int32_t rc = PWXrslamTransportGetLastTimestampTrace(stream, &trace);
  const jdouble values[] = {
      static_cast<jdouble>(trace.stream),
      static_cast<jdouble>(trace.status),
      trace.raw_timestamp,
      trace.applied_offset,
      trace.effective_timestamp,
      static_cast<jdouble>(trace.submitted_sequence),
  };
  env->SetDoubleArrayRegion(out, 0, 6, values);
  return rc;
}

// out[9] = {lifecycle_generation, camera_submitted, camera_run_calls,
//           acceleration_submitted, gyroscope_submitted,
//           rejected_invalid_argument, rejected_non_monotonic,
//           rejected_not_running, running}
extern "C" JNIEXPORT jint JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativeGetCounters(
    JNIEnv* env, jobject, jlongArray out) {
  if (out == nullptr || env->GetArrayLength(out) < 9) return -1;
  PWXrslamTransportCounters counters{};
  const int32_t rc = PWXrslamTransportGetCounters(&counters);
  const jlong values[] = {
      static_cast<jlong>(counters.lifecycle_generation),
      static_cast<jlong>(counters.camera_submitted),
      static_cast<jlong>(counters.camera_run_calls),
      static_cast<jlong>(counters.acceleration_submitted),
      static_cast<jlong>(counters.gyroscope_submitted),
      static_cast<jlong>(counters.rejected_invalid_argument),
      static_cast<jlong>(counters.rejected_non_monotonic),
      static_cast<jlong>(counters.rejected_not_running),
      static_cast<jlong>(counters.running),
  };
  env->SetLongArrayRegion(out, 0, 9, values);
  return rc;
}
