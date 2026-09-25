// PwXrReconChainCore.cpp —— 见同名 .h 的文件头(规则 R1–R6)。只进台架。
//
// 方法地图(pocketworld CLAUDE.md「上游复刻铁律」口径):
//   exact_upstream  : 外推 = 引擎 XRSLAMPropagateBackendState(→ detail.cpp propagate_state_okvis2,OKVIS2
//                     ImuError::propagation 离散的逐句移植,见引擎提交);后端状态 = 引擎只读出口原值。
//   product_adapter : R1–R6(等哪一帧、等多久、何时算不可信)。这些是用户 2026-09-25 拍板的链路规则,
//                     不是算法;没有任何插值 / 平滑 / 补偿。
//   not_implemented : 无。
//
// 线程:所有入口持同一把锁;锁内会调引擎的只读出口(它们各有自己的锁,不回调本文件)。

#include "PwXrReconChainCore.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <vector>

#include "../include/XRSLAM.h"
#include "../include/XRSLAMBackendPose.h"

namespace {

struct BackendFrame {
  bool has_first = false;
  bool has_final = false;
  XRSLAMBackendState first{};
  XRSLAMBackendState final_state{};
};

struct Pending {
  int64_t photo_id;
  double t_photo;
  double submitted_at;
};

struct Chain {
  PwXrChainConfig cfg{3.0, 0.1};
  // 帧状态(引擎时刻, XRSLAMState),按时间递增报进来。
  std::deque<std::pair<double, int32_t>> frame_states;
  // 后端帧:键 = 帧时刻(XRSLAMBackendPose.timestamp,与 PushImage 的时间戳逐位相同)。
  std::map<double, BackendFrame> backend;
  double latest_first_t = -1e300;
  std::vector<Pending> pending;
  std::deque<PwXrChainPhotoResult> results;
  std::vector<int64_t> seen_ids;
  int64_t stats[14] = {0};
  std::vector<XRSLAMBackendState> buf = std::vector<XRSLAMBackendState>(1024);
};

std::mutex g_mu;
Chain g_chain;

constexpr size_t kFrameStateCap = 1 << 15;  // 30 Hz 约 18 分钟

void DrainLocked(Chain &c) {
  for (;;) {
    unsigned long long dropped = 0;
    const int n = XRSLAMDrainBackendStates(c.buf.data(), static_cast<int>(c.buf.size()), &dropped);
    ++c.stats[13];
    c.stats[3] += static_cast<int64_t>(dropped);
    if (n <= 0) break;
    for (int i = 0; i < n; ++i) {
      const XRSLAMBackendState &s = c.buf[i];
      const double t = s.pose.timestamp;
      BackendFrame &f = c.backend[t];
      if (s.pose.kind == XRSLAM_BACKEND_POSE_FIRST) {
        ++c.stats[1];
        if (!f.has_first) {  // 出口已按帧号去重,这里再保守一次:只记第一次
          f.has_first = true;
          f.first = s;
        }
        if (t > c.latest_first_t) c.latest_first_t = t;
      } else if (s.pose.kind == XRSLAM_BACKEND_POSE_FINAL) {
        ++c.stats[2];
        f.has_final = true;  // 离窗前最后状态;同一帧只会离窗一次
        f.final_state = s;
      }
    }
    if (n < static_cast<int>(c.buf.size())) break;
  }
}

// R2:FIRST 时刻 ≤ t_photo 的最大后端帧。没有返回 nullptr。
const std::pair<const double, BackendFrame> *LatestBackendAtOrBefore(const Chain &c, double t_photo) {
  auto it = c.backend.upper_bound(t_photo);
  while (it != c.backend.begin()) {
    --it;
    if (it->second.has_first) return &*it;
  }
  return nullptr;
}

int32_t EngineStateAt(const Chain &c, double t_photo) {
  // 引擎时刻 ≤ t_photo 的最后一帧。frame_states 按时间递增。
  auto it = std::upper_bound(c.frame_states.begin(), c.frame_states.end(), t_photo,
                             [](double v, const std::pair<double, int32_t> &e) { return v < e.first; });
  if (it == c.frame_states.begin()) return -1;
  --it;
  return it->second;
}

void FillFromPropagated(PwXrChainPhotoResult &r, const XRSLAMPropagatedState &p) {
  for (int i = 0; i < 4; ++i) {
    r.camera_q[i] = p.quaternion[i];
    r.body_q[i] = p.body_quaternion[i];
  }
  for (int i = 0; i < 3; ++i) {
    r.camera_p[i] = p.translation[i];
    r.body_p[i] = p.body_translation[i];
  }
  r.propagated_t = p.timestamp;
  r.imu_samples = p.imu_samples;
  r.propagate_status = p.status;
  r.has_pose = 1;
}

void Finish(Chain &c, const Pending &p, double now, int32_t source,
            const std::pair<const double, BackendFrame> *b, const XRSLAMBackendState *start,
            int32_t start_kind, int32_t extra_reasons) {
  PwXrChainPhotoResult r;
  std::memset(&r, 0, sizeof(r));
  r.photo_id = p.photo_id;
  r.t_photo = p.t_photo;
  r.submitted_at = p.submitted_at;
  r.resolved_at = now;
  r.source = source;
  r.propagate_status = -100;
  r.engine_state_at_photo = EngineStateAt(c, p.t_photo);
  int32_t reasons = extra_reasons;
  if (b) {
    r.t_state = b->first;
    r.extrapolation_s = p.t_photo - b->first;
    r.frame_id = b->second.first.pose.frame_id;
  }
  if (start) {
    XRSLAMPropagatedState ps;
    XRSLAMPropagateBackendState(start, p.t_photo, &ps);
    FillFromPropagated(r, ps);
    r.state_kind = start_kind;
    if (ps.status != XRSLAM_PROPAGATE_OK) reasons |= PW_XRCHAIN_UNTRUSTED_PROPAGATE_FAILED;
  } else {
    reasons |= PW_XRCHAIN_UNTRUSTED_PROPAGATE_FAILED;
  }
  if (source == PW_XRCHAIN_SOURCE_TIMEOUT) reasons |= PW_XRCHAIN_UNTRUSTED_TIMEOUT;
  if (source == PW_XRCHAIN_SOURCE_NO_BACKEND_FRAME) reasons |= PW_XRCHAIN_UNTRUSTED_NO_BACKEND_FRAME;
  if (b && !(r.extrapolation_s <= c.cfg.max_extrapolation_s))
    reasons |= PW_XRCHAIN_UNTRUSTED_EXTRAPOLATION_TOO_LONG;
  if (r.engine_state_at_photo < 0)
    reasons |= PW_XRCHAIN_UNTRUSTED_NO_STATE_AT_PHOTO;
  else if (r.engine_state_at_photo != XRSLAM_STATE_TRACKING_SUCCESS)
    reasons |= PW_XRCHAIN_UNTRUSTED_NOT_TRACKING;
  r.untrusted_reasons = reasons;
  r.trusted = (reasons == 0 && (source == PW_XRCHAIN_SOURCE_FINAL ||
                                source == PW_XRCHAIN_SOURCE_WINDOW_AT_CLOSE))
                  ? 1
                  : 0;
  ++c.stats[5];
  if (source == PW_XRCHAIN_SOURCE_FINAL) ++c.stats[6];
  if (source == PW_XRCHAIN_SOURCE_WINDOW_AT_CLOSE) ++c.stats[7];
  if (source == PW_XRCHAIN_SOURCE_TIMEOUT) ++c.stats[8];
  if (source == PW_XRCHAIN_SOURCE_NO_BACKEND_FRAME) ++c.stats[9];
  ++c.stats[r.trusted ? 10 : 11];
  c.results.push_back(r);
}

// R2–R4。closing = true 时不再等新帧(R5 前半)。返回本次给出结果数。
int32_t AdvanceLocked(Chain &c, double now, bool closing,
                      const std::map<double, XRSLAMBackendState> *window) {
  int32_t done = 0;
  std::vector<Pending> keep;
  keep.reserve(c.pending.size());
  for (const Pending &p : c.pending) {
    const bool b_known = closing || c.latest_first_t > p.t_photo;
    const auto *b = b_known ? LatestBackendAtOrBefore(c, p.t_photo) : nullptr;
    if (b_known && !b) {
      Finish(c, p, now, PW_XRCHAIN_SOURCE_NO_BACKEND_FRAME, nullptr, nullptr, 0, 0);
      ++done;
      continue;
    }
    if (b && b->second.has_final) {
      Finish(c, p, now, PW_XRCHAIN_SOURCE_FINAL, b, &b->second.final_state, XRSLAM_BACKEND_POSE_FINAL, 0);
      ++done;
      continue;
    }
    if (closing) {
      auto w = window ? window->find(b->first) : std::map<double, XRSLAMBackendState>::const_iterator();
      if (window && w != window->end()) {
        Finish(c, p, now, PW_XRCHAIN_SOURCE_WINDOW_AT_CLOSE, b, &w->second, XRSLAM_BACKEND_POSE_WINDOW, 0);
      } else {
        // 既无 FINAL 也不在收尾窗口:不可信;位姿按 R4 的做法取 FIRST(只存档)。
        Finish(c, p, now, PW_XRCHAIN_SOURCE_WINDOW_AT_CLOSE, b, &b->second.first, XRSLAM_BACKEND_POSE_FIRST,
               PW_XRCHAIN_UNTRUSTED_NOT_IN_CLOSE_WINDOW);
      }
      ++done;
      continue;
    }
    if (now - p.t_photo > c.cfg.final_timeout_s) {
      // b 还没认定(后端还没处理到拍照之后的帧)时,存档位姿取目前 ≤ t_photo 的最近后端帧。
      const auto *b2 = b ? b : LatestBackendAtOrBefore(c, p.t_photo);
      const XRSLAMBackendState *start = (b2 && b2->second.has_first) ? &b2->second.first : nullptr;
      Finish(c, p, now, PW_XRCHAIN_SOURCE_TIMEOUT, b2, start, start ? XRSLAM_BACKEND_POSE_FIRST : 0, 0);
      ++done;
      continue;
    }
    keep.push_back(p);
  }
  c.pending.swap(keep);
  return done;
}

}  // namespace

extern "C" void pw_xrchain_reset(const PwXrChainConfig *cfg) {
  std::lock_guard<std::mutex> lk(g_mu);
  g_chain = Chain();
  if (cfg) g_chain.cfg = *cfg;
}

extern "C" void pw_xrchain_note_frame(double t_frame, int32_t state) {
  std::lock_guard<std::mutex> lk(g_mu);
  Chain &c = g_chain;
  if (!std::isfinite(t_frame)) return;
  if (!c.frame_states.empty() && t_frame <= c.frame_states.back().first) return;  // 只收递增
  c.frame_states.emplace_back(t_frame, state);
  while (c.frame_states.size() > kFrameStateCap) c.frame_states.pop_front();
  ++c.stats[0];
}

extern "C" int32_t pw_xrchain_submit_photo(int64_t photo_id, double t_photo, double now) {
  std::lock_guard<std::mutex> lk(g_mu);
  Chain &c = g_chain;
  if (std::find(c.seen_ids.begin(), c.seen_ids.end(), photo_id) != c.seen_ids.end()) return -1;
  c.seen_ids.push_back(photo_id);
  c.pending.push_back({photo_id, t_photo, now});
  ++c.stats[4];
  return 0;
}

extern "C" int32_t pw_xrchain_poll(double now) {
  std::lock_guard<std::mutex> lk(g_mu);
  DrainLocked(g_chain);
  return AdvanceLocked(g_chain, now, false, nullptr);
}

extern "C" int32_t pw_xrchain_close(double now) {
  std::lock_guard<std::mutex> lk(g_mu);
  Chain &c = g_chain;
  DrainLocked(c);
  int32_t done = AdvanceLocked(c, now, false, nullptr);
  if (c.pending.empty()) return done;
  std::vector<XRSLAMBackendState> wbuf(256);
  int n = XRSLAMGetBackendWindowStates(wbuf.data(), static_cast<int>(wbuf.size()));
  if (n > static_cast<int>(wbuf.size())) {
    wbuf.resize(static_cast<size_t>(n));
    n = XRSLAMGetBackendWindowStates(wbuf.data(), static_cast<int>(wbuf.size()));
  }
  std::map<double, XRSLAMBackendState> window;
  for (int i = 0; i < n && i < static_cast<int>(wbuf.size()); ++i) window[wbuf[i].pose.timestamp] = wbuf[i];
  c.stats[12] = n < 0 ? -1 : n;
  done += AdvanceLocked(c, now, true, &window);
  return done;
}

extern "C" int32_t pw_xrchain_take_result(PwXrChainPhotoResult *out) {
  std::lock_guard<std::mutex> lk(g_mu);
  if (g_chain.results.empty() || out == nullptr) return 0;
  *out = g_chain.results.front();
  g_chain.results.pop_front();
  return 1;
}

extern "C" int32_t pw_xrchain_pending_count(void) {
  std::lock_guard<std::mutex> lk(g_mu);
  return static_cast<int32_t>(g_chain.pending.size());
}

extern "C" void pw_xrchain_stats(int64_t *out, int32_t n) {
  std::lock_guard<std::mutex> lk(g_mu);
  if (out == nullptr) return;
  for (int32_t i = 0; i < n && i < 14; ++i) out[i] = g_chain.stats[i];
}

#ifdef PW_XRCHAIN_ENGINE_WEAK_FALLBACK
// 只在台架 iOS Runner 里带上(pbxproj 逐文件旗标):链进来的引擎臂没有这些出口时如实得到「没有」,
// 不让别的引擎臂链接失败(同 ios/Runner/PwBenchReplayEngineProbe.c ③ 的做法)。引擎归档有强定义时用引擎的。
// Mac 回放器动态链接引擎,不能带这组弱定义(可执行文件自己的定义会盖过 dylib)。
extern "C" __attribute__((weak)) int XRSLAMDrainBackendStates(XRSLAMBackendState *out, int capacity,
                                                             unsigned long long *dropped) {
  (void)out; (void)capacity;
  if (dropped) *dropped = 0;
  return -1;
}
extern "C" __attribute__((weak)) int XRSLAMGetBackendWindowStates(XRSLAMBackendState *out, int capacity) {
  (void)out; (void)capacity;
  return -1;
}
extern "C" __attribute__((weak)) int XRSLAMPropagateBackendState(const XRSLAMBackendState *state, double t,
                                                                XRSLAMPropagatedState *out) {
  (void)state; (void)t;
  if (out) {
    std::memset(out, 0, sizeof(*out));
    out->status = XRSLAM_PROPAGATE_INVALID;
  }
  return XRSLAM_PROPAGATE_INVALID;
}
#endif
