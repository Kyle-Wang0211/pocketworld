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

// [pw 2026-09-23] Per-frame intrinsics. Appended after the three legacy entry
// points so their line numbers (cited in lib/vio/ffi/xrslam_live_ffi.dart)
// stay put. `intrinsics` == null => byte-for-byte the legacy push
// (PWXrslamTransportPushCameraAndRunRawWithIntrinsics with k == NULL);
// otherwise exactly four doubles fx, fy, cx, cy in pixels of the buffer being
// pushed (the Kotlin caller owns any coordinate conversion; see the TODO in
// PwXrslamTransport.kt). A wrong length is rejected before any ABI call.
extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativePushCameraAndRunRawWithIntrinsics(
    JNIEnv* env, jobject, jobject buffer, jdouble timestamp, jint stride,
    jint camera_id, jint channel, jdoubleArray intrinsics) {
  auto* data = static_cast<unsigned char*>(env->GetDirectBufferAddress(buffer));
  int32_t raw_state = 0;
  PWXrslamRawPose raw_pose{};
  int32_t transport_rc = PW_XRSLAM_ERR_INVALID_ARGUMENT;
  if (intrinsics == nullptr) {
    transport_rc = PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
        data, timestamp, stride, camera_id, channel, nullptr, &raw_state,
        &raw_pose);
  } else if (env->GetArrayLength(intrinsics) == 4) {
    jdouble k[4] = {0.0, 0.0, 0.0, 0.0};
    env->GetDoubleArrayRegion(intrinsics, 0, 4, k);
    const double k_fxfycxcy[4] = {k[0], k[1], k[2], k[3]};
    transport_rc = PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
        data, timestamp, stride, camera_id, channel, k_fxfycxcy, &raw_state,
        &raw_pose);
  }
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

// Raw copy of PWXrslamIntrinsicsTrace (the shared C++ ledger). Order:
// [rc, camera_submitted_sequence, last_per_frame_attached,
//  last_engine_report_read, last_engine_report_matches,
//  last_attached fx fy cx cy, last_engine fx fy cx cy,
//  attached, not_attached, rejected_invalid, engine_report_matched]
extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_pocketworld_capture_PwXrslamTransport_nativeIntrinsicsTrace(
    JNIEnv* env, jobject) {
  PWXrslamIntrinsicsTrace t{};
  const int32_t rc = PWXrslamTransportGetIntrinsicsTrace(&t);
  const jdouble values[] = {
      static_cast<jdouble>(rc),
      static_cast<jdouble>(t.camera_submitted_sequence),
      static_cast<jdouble>(t.last_per_frame_attached),
      static_cast<jdouble>(t.last_engine_report_read),
      static_cast<jdouble>(t.last_engine_report_matches),
      t.last_attached_fxfycxcy[0],
      t.last_attached_fxfycxcy[1],
      t.last_attached_fxfycxcy[2],
      t.last_attached_fxfycxcy[3],
      t.last_engine_fxfycxcy[0],
      t.last_engine_fxfycxcy[1],
      t.last_engine_fxfycxcy[2],
      t.last_engine_fxfycxcy[3],
      static_cast<jdouble>(t.attached),
      static_cast<jdouble>(t.not_attached),
      static_cast<jdouble>(t.rejected_invalid),
      static_cast<jdouble>(t.engine_report_matched),
  };
  constexpr jsize kCount = static_cast<jsize>(sizeof(values) / sizeof(values[0]));
  jdoubleArray result = env->NewDoubleArray(kCount);
  if (result != nullptr) env->SetDoubleArrayRegion(result, 0, kCount, values);
  return result;
}
