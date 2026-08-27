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
