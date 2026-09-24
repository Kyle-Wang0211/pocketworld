// PwBenchReplayEngineProbe.c —— 见同名 .h 的文件头。只读,不改任何引擎状态。

#include "PwBenchReplayEngineProbe.h"

#include <math.h>

#include "XRSLAM.h"

void PWBenchReplayReadBodyPose(PWXrslamRawPose *out) {
  if (out == 0) return;
  XRSLAMPose pose;
  pose.timestamp = 0;
  for (int i = 0; i < 4; ++i) pose.quaternion[i] = 0;
  for (int i = 0; i < 3; ++i) pose.translation[i] = 0;
  XRSLAMGetResult(XRSLAM_RESULT_BODY_POSE, &pose);
  // 与传输层 CopyRawPose(PwXrslamTransportCore.cpp)同样逐字段拷。
  out->timestamp = pose.timestamp;
  for (int i = 0; i < 4; ++i) out->quaternion[i] = pose.quaternion[i];
  for (int i = 0; i < 3; ++i) out->translation[i] = pose.translation[i];
}

// ── 遥测(euroc_runner.cpp @b0937ef Telemetry::bind 的同一张符号表)──────────
// 弱定义 + 哨兵(见 .h ②)。类型与引擎一致:solver.cpp 是 std::atomic<unsigned long long>
// (arm64 上无锁、布局即裸 u64),frontend_worker.cpp 是 double / unsigned long long。
#define PW_TELEMETRY_ABSENT_U64 0xFFFFFFFFFFFFFFFFULL
#define PW_TELEMETRY_ABSENT_MS (-1.0)
__attribute__((weak)) unsigned long long pw_solver_scoped_ns = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) unsigned long long pw_solver_scoped_calls = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) unsigned long long pw_solver_scoped_iterations = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) unsigned long long pw_solver_unscoped_ns = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) unsigned long long pw_solver_stop_budget = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) unsigned long long pw_solver_stop_time_limit = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) unsigned long long pw_solver_stop_iter_limit = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) unsigned long long pw_solver_stop_converged = PW_TELEMETRY_ABSENT_U64;
__attribute__((weak)) double pw_bk_work_ms = PW_TELEMETRY_ABSENT_MS;
__attribute__((weak)) double pw_bk_track_ms = PW_TELEMETRY_ABSENT_MS;
__attribute__((weak)) unsigned long long pw_bk_track_n = PW_TELEMETRY_ABSENT_U64;

// runner 用 load()(seq_cst);这里同一内存序。哨兵 ⇒ −1。
static int64_t LoadCount(const unsigned long long *p) {
  const unsigned long long v = __atomic_load_n(p, __ATOMIC_SEQ_CST);
  return v == PW_TELEMETRY_ABSENT_U64 ? -1 : (int64_t)v;
}

static double LoadNsAsMs(const unsigned long long *p) {
  const unsigned long long v = __atomic_load_n(p, __ATOMIC_SEQ_CST);
  return v == PW_TELEMETRY_ABSENT_U64 ? NAN : (double)v * 1e-6;
}

static double LoadMs(const double *p) {
  const double v = *(const volatile double *)p;
  return v == PW_TELEMETRY_ABSENT_MS ? NAN : v;
}

void PWBenchReplayTelemetryTake(PWBenchReplayTelemetry *out) {
  if (out == 0) return;
  out->scoped_ms = LoadNsAsMs(&pw_solver_scoped_ns);
  out->unscoped_ms = LoadNsAsMs(&pw_solver_unscoped_ns);
  out->bk_work_ms = LoadMs(&pw_bk_work_ms);
  out->bk_track_ms = LoadMs(&pw_bk_track_ms);
  out->scoped_calls = LoadCount(&pw_solver_scoped_calls);
  out->scoped_iters = LoadCount(&pw_solver_scoped_iterations);
  out->stop_budget = LoadCount(&pw_solver_stop_budget);
  out->stop_time = LoadCount(&pw_solver_stop_time_limit);
  out->stop_iter = LoadCount(&pw_solver_stop_iter_limit);
  out->stop_conv = LoadCount(&pw_solver_stop_converged);
  out->bk_track_n = LoadCount(&pw_bk_track_n);
}

int32_t PWBenchReplayTelemetrySymbolCount(void) {
  PWBenchReplayTelemetry t;
  PWBenchReplayTelemetryTake(&t);
  int32_t n = 0;
  n += !isnan(t.scoped_ms);
  n += !isnan(t.unscoped_ms);
  n += !isnan(t.bk_work_ms);
  n += !isnan(t.bk_track_ms);
  n += t.scoped_calls >= 0;
  n += t.scoped_iters >= 0;
  n += t.stop_budget >= 0;
  n += t.stop_time >= 0;
  n += t.stop_iter >= 0;
  n += t.stop_conv >= 0;
  n += t.bk_track_n >= 0;
  return n;
}
