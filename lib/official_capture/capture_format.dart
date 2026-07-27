// capture_format.dart — E24 会话视频格式的单一事实源(dart-define 驱动)。
//
// PW_VIDEO_FORMAT:
//   'hires43'(默认,E24 转正):会话=高清捕获推荐格式(1920×1440 4:3),
//     静照=4032×3024 12MP 4:3(2026-07-19 真机判活:tracking 正常,推翻
//     历史"12MP in-session 互斥"注释);快门证据=静照,photo==fed 1:1 恢复。
//   '4k'(回退):会话=3840×2160 16:9,证据=视频帧(旧认证世界),供
//     S3 九门对照与问题回退。
//   'default43'(探针遗留):系统默认档,静照仅 2016×1512,已判死,仅留档。
// The official route is fail-closed on one capture format. Build-time
// overrides remain available only to the self-developed physical copy.
const String pwVideoFormat = 'hires43';

/// photo43 = 静照即证据模式(E24 主形态)。
const bool pwPhoto43 = true;

/// 取景画幅(竖屏 w/h):photo43=3:4,其余=9:16 —— WYSIWYG:预览画幅
/// 恒等于照片画幅(用户规格 2026-07-19:拍摄阶段 AR 与照片显示相同画面)。
/// 取景矩形的位置/尺寸与底部控件条的几何在
/// `lib/ui/official_capture/capture_preview_rect.dart`(那边要 dart:ui,
/// 本文件保持纯常量)。
const double pwPreviewAspect = 3 / 4;
