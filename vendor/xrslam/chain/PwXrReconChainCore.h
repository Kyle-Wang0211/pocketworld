// PwXrReconChainCore.h —— 台架 XRSLAM → SfM 重建链的「照片位姿」核心(C ABI,跨端 C++,只进台架)。
//
// ══ 用户 2026-09-25 拍板的链路(本文件只做其中「照片位姿」一段)═══════════════════════════
//   实时预览 = XRSLAM 前端输出;照片 = 零 ARKit 采集的 4:3 静态照;
//   照片位姿 = 拍照时刻 t_photo 之前最近一个**后端帧**的**定稿**状态(位姿 + 速度 + 零偏),
//              用引擎**官方**外推(XRSLAMPropagateBackendState → propagate_state_okvis2)推到 t_photo;
//              不插值、不平滑、不发明任何补偿;
//   喂 SfM = pwofficial_add_jpeg_frame_v2(..., device_pose_trusted),不可信的走核里上游 RegisterNextImage
//              证据门;交付尺度沿用核内 Sim3 对齐。核不改。
//
// ══ 本文件的规则(逐条,全部在 .cpp 的 Resolve* 里,Mac 回放与手机跑同一份源码)══════════════
//   R1 后端帧 = 出过 FIRST 事件的帧(XRSLAMDrainBackendStates kind 1)。
//   R2 「t_photo 之前最近的后端帧」b = FIRST 时刻 ≤ t_photo 的最大者;只有在见到一条 FIRST 时刻 > t_photo
//      之后(后端已经处理过拍照之后的帧 ⇒ ≤ t_photo 的后端帧都已出过 FIRST)才认定 b,收尾时直接认定。
//   R3 等 b 的 FINAL(kind 2,离窗前最后状态 = 定稿);拿到即用官方外推推到 t_photo ⇒ 来源 FINAL。
//   R4 超时:宿主时钟 now − t_photo > final_timeout_s 仍没等到 FINAL ⇒ 来源 TIMEOUT,不可信(0)。
//      位姿仍按 R3 的外推法从 b 的 FIRST 状态给一份(只随帧存档;核对不可信帧不用它,见 official_sfm_c.h)。
//   R5 收尾(pw_xrchain_close):仍在等的照片,b 已有 FINAL 就按 R3;否则取收尾窗口快照
//      (XRSLAMGetBackendWindowStates,kind 3)里 b 的状态外推 ⇒ 来源 WINDOW_AT_CLOSE。
//   R6 可信(1)当且仅当:来源 ∈ {FINAL, WINDOW_AT_CLOSE} 且 外推状态 == XRSLAM_PROPAGATE_OK 且
//      外推长度 t_photo − t_b ≤ max_extrapolation_s 且 拍照时刻引擎状态 == TRACKING_SUCCESS
//      (拍照时刻引擎状态 = 引擎时刻 ≤ t_photo 的最后一帧的 XRSLAM_RESULT_STATE,由宿主逐帧报进来)。
//      任何一条不满足 ⇒ 0,原因按位记在 untrusted_reasons。
//
// ══ 时间 ═══════════════════════════════════════════════════════════════════════════
//   t_photo / 帧时刻 / 后端记录时刻 = 引擎时域(宿主推给引擎的相机时间戳,含曝光中点、c 与 Δ)。
//   now = 宿主单调时钟,与相机 PTS / CoreMotion 时间戳同域(手机:CACurrentMediaTime;Mac 回放:
//   最近推进引擎的数据时刻)。超时只比 now − t_photo,毫秒级的 c/Δ 差对秒级超时无影响。
//
// ══ 平台 ═══════════════════════════════════════════════════════════════════════════
//   本文件与 .cpp 只用标准库与 XRSLAM C 接口;没有任何平台宏、平台 API。平台代码(相机 / 快门 /
//   时钟)只在宿主(iOS:ios/Runner/PwXrReconChain.swift)。

#ifndef PW_XR_RECON_CHAIN_CORE_H_
#define PW_XR_RECON_CHAIN_CORE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 照片位姿来源。数值固定,只加不改。 */
enum {
  PW_XRCHAIN_SOURCE_PENDING = 0,          /*!< 还在等(只出现在 pw_xrchain_pending_snapshot)。 */
  PW_XRCHAIN_SOURCE_FINAL = 1,            /*!< b 的 FINAL 定稿状态 + 官方外推。 */
  PW_XRCHAIN_SOURCE_WINDOW_AT_CLOSE = 2,  /*!< 收尾时 b 仍在后端窗口:收尾窗口快照 + 官方外推。 */
  PW_XRCHAIN_SOURCE_TIMEOUT = 3,          /*!< 等定稿超时(不可信);位姿取 b 的 FIRST + 官方外推(若有)。 */
  PW_XRCHAIN_SOURCE_NO_BACKEND_FRAME = 4  /*!< 拍照时刻之前没有任何后端帧(不可信,无位姿)。 */
};

/** 不可信原因(按位)。 */
enum {
  PW_XRCHAIN_UNTRUSTED_TIMEOUT = 1 << 0,              /*!< R4 */
  PW_XRCHAIN_UNTRUSTED_EXTRAPOLATION_TOO_LONG = 1 << 1,/*!< t_photo − t_b > max_extrapolation_s */
  PW_XRCHAIN_UNTRUSTED_NOT_TRACKING = 1 << 2,         /*!< 拍照时刻引擎状态 != TRACKING_SUCCESS */
  PW_XRCHAIN_UNTRUSTED_NO_STATE_AT_PHOTO = 1 << 3,    /*!< 拍照时刻之前宿主没报过任何帧状态 */
  PW_XRCHAIN_UNTRUSTED_PROPAGATE_FAILED = 1 << 4,     /*!< 外推返回码 != XRSLAM_PROPAGATE_OK */
  PW_XRCHAIN_UNTRUSTED_NO_BACKEND_FRAME = 1 << 5,     /*!< 来源 NO_BACKEND_FRAME */
  PW_XRCHAIN_UNTRUSTED_NOT_IN_CLOSE_WINDOW = 1 << 6   /*!< 收尾时 b 既无 FINAL 也不在收尾窗口 */
};

typedef struct PwXrChainConfig {
  double final_timeout_s;      /*!< R4 超时(秒)。 */
  double max_extrapolation_s;  /*!< R6 外推长度上限(秒),用户定 0.1。 */
} PwXrChainConfig;

typedef struct PwXrChainPhotoResult {
  int64_t photo_id;
  double t_photo;              /*!< 引擎时域拍照时刻(宿主提交的原值)。 */
  double submitted_at;         /*!< 提交时的 now。 */
  double resolved_at;          /*!< 给出结果时的 now。 */
  double t_state;              /*!< b 的帧时刻(无 b 时 0)。 */
  double extrapolation_s;      /*!< t_photo − t_state(无 b 时 0)。 */
  double camera_q[4];          /*!< 相机位姿(world_from_camera,XRSLAM world / OpenCV 相机轴)[x,y,z,w]。 */
  double camera_p[3];          /*!< 相机中心(XRSLAM world)。 */
  double body_q[4];            /*!< body 位姿 [x,y,z,w]。 */
  double body_p[3];
  double propagated_t;         /*!< 外推实际到达时刻(XRSLAMPropagatedState.timestamp)。 */
  uint64_t frame_id;           /*!< b 的引擎帧号。 */
  int32_t source;              /*!< PW_XRCHAIN_SOURCE_* */
  int32_t trusted;             /*!< 1 可信 / 0 不可信 */
  int32_t untrusted_reasons;   /*!< PW_XRCHAIN_UNTRUSTED_* 按位或 */
  int32_t engine_state_at_photo;/*!< 引擎时刻 ≤ t_photo 的最后一帧的 XRSLAMState;-1 = 没有 */
  int32_t state_kind;          /*!< 外推起点记录的 kind(1 FIRST / 2 FINAL / 3 WINDOW;0 无) */
  int32_t propagate_status;    /*!< XRSLAM_PROPAGATE_*;没外推时 -100 */
  int32_t imu_samples;         /*!< 参与外推积分的 IMU 样本数 */
  int32_t has_pose;            /*!< 1 = camera_* / body_* 有效 */
} PwXrChainPhotoResult;

/** 新会话:清空全部状态并设定参数。引擎会话建好之后、推第一帧之前调。 */
void pw_xrchain_reset(const PwXrChainConfig *cfg);

/** 每推完一帧(RunOneFrame + GetResult 之后)报一次:该帧引擎时刻与 XRSLAM_RESULT_STATE 原值。 */
void pw_xrchain_note_frame(double t_frame, int32_t state);

/** 提交一张照片(t_photo 为引擎时域)。返回 0;photo_id 重复返回 -1。 */
int32_t pw_xrchain_submit_photo(int64_t photo_id, double t_photo, double now);

/** 取走引擎的后端事件,按 R2–R4 推进在等的照片。返回本次新给出结果的照片数。 */
int32_t pw_xrchain_poll(double now);

/**
 * 收尾(R5):调用方须先停止喂新帧并等引擎 worker 排空(否则收尾窗口不是最终窗口)。
 * 先做一次 poll,再按收尾窗口给出所有仍在等的照片。返回本次新给出结果的照片数。
 */
int32_t pw_xrchain_close(double now);

/** 按给出顺序取走一条结果。1 = 取到;0 = 没有。 */
int32_t pw_xrchain_take_result(PwXrChainPhotoResult *out);

/** 在等的照片数。 */
int32_t pw_xrchain_pending_count(void);

/**
 * 计数(按下标):0 帧状态条数 1 FIRST 事件数 2 FINAL 事件数 3 引擎队列丢弃数 4 已提交照片
 * 5 已给出结果 6 FINAL 来源 7 WINDOW_AT_CLOSE 来源 8 TIMEOUT 来源 9 NO_BACKEND_FRAME 来源
 * 10 可信 11 不可信 12 收尾时窗口快照条数 13 drain 调用次数。n 为 out 容量。
 */
void pw_xrchain_stats(int64_t *out, int32_t n);

#ifdef __cplusplus
}
#endif

#endif  // PW_XR_RECON_CHAIN_CORE_H_
