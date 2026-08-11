// capture_exit_dialog.dart — 拍摄中退出的确认弹窗(黑白 + 滑轴)。
//
// [2026-08-09 用户签决,附截图] 原弹窗是 Material 蓝绿色 AlertDialog,只有
// "退出并丢弃"一条出路。改:
//   • 颜色黑白(与设计册一致,红色仅用于破坏性状态);
//   • 第一行 = 左右滑动的滑轴,滑块只能停在左右两侧:
//       滑块在左(默认)→ 轨道黑底白字"退出并保存照片";
//       滑到右侧      → 轨道红底白字"退出并不保存照片";
//     点轨道文字区 = 执行当前显示的动作(滑动本身只切换,不执行 ——
//     "不保存"是破坏性动作,必须"滑过去再点"两步确认);
//   • 第二行 = "继续拍摄";
//   • 点弹窗外任意处 = 自动返回拍摄(barrierDismissible)。
import 'package:flutter/material.dart';

/// 弹窗结果。null(点外面/继续拍摄)= 回拍摄。
enum CaptureExitChoice {
  /// 退出并保存照片:照片进草稿(未完成态,可断点续跑),不丢任何数据。
  saveExit,

  /// 退出并不保存照片:丢弃本次素材(原有"退出并丢弃"的算法)。
  discardExit,
}

/// 破坏性红(与草稿卡"未完成"胶囊同一支 iOS systemRed)。
const Color kCaptureExitDangerRed = Color(0xFFFF3B30);

Future<CaptureExitChoice?> showCaptureExitDialog(BuildContext context) {
  return showDialog<CaptureExitChoice>(
    context: context,
    // 点屏幕其他地方 = 自动返回拍摄。
    barrierDismissible: true,
    builder: (_) => const CaptureExitDialog(),
  );
}

class CaptureExitDialog extends StatefulWidget {
  const CaptureExitDialog({super.key});

  @override
  State<CaptureExitDialog> createState() => _CaptureExitDialogState();
}

class _CaptureExitDialogState extends State<CaptureExitDialog> {
  /// 滑块停靠侧。false = 左(保存),true = 右(不保存)。
  bool _right = false;

  /// 拖动中的临时位置(0..1),null = 未在拖。
  double? _dragT;

  static const double _trackH = 56;
  static const double _thumbD = 44;
  static const double _pad = (_trackH - _thumbD) / 2;

  @visibleForTesting
  bool get debugRight => _right;

  void _confirm() {
    Navigator.of(
      context,
    ).pop(_right ? CaptureExitChoice.discardExit : CaptureExitChoice.saveExit);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '退出拍摄？',
              style: TextStyle(
                color: Colors.black,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            _buildSlider(),
            const SizedBox(height: 6),
            TextButton(
              key: const ValueKey('capture-exit-continue'),
              onPressed: () => Navigator.of(context).pop(null),
              style: TextButton.styleFrom(
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text(
                '继续拍摄',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider() {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final travel = w - _thumbD - _pad * 2;
        final t = _dragT ?? (_right ? 1.0 : 0.0);
        final thumbX = _pad + travel * t;
        // 拖动过半即预览红色状态 —— 松手才落定。
        final showDanger = t > 0.5;
        return GestureDetector(
          key: const ValueKey('capture-exit-slider'),
          behavior: HitTestBehavior.opaque,
          // 点文字区 = 执行当前显示的动作。
          onTap: _confirm,
          onHorizontalDragStart: (d) => setState(
            () => _dragT = ((d.localPosition.dx - _pad - _thumbD / 2) / travel)
                .clamp(0.0, 1.0),
          ),
          onHorizontalDragUpdate: (d) => setState(
            () => _dragT = ((d.localPosition.dx - _pad - _thumbD / 2) / travel)
                .clamp(0.0, 1.0),
          ),
          onHorizontalDragEnd: (_) => setState(() {
            // 只能停在左右两侧:按松手位置就近吸附。
            _right = (_dragT ?? 0) > 0.5;
            _dragT = null;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: _trackH,
            decoration: BoxDecoration(
              color: showDanger ? kCaptureExitDangerRed : Colors.black,
              borderRadius: BorderRadius.circular(_trackH / 2),
            ),
            child: Stack(
              children: [
                // 文字放在滑块不在的那半边。
                Positioned.fill(
                  left: showDanger ? _pad : _thumbD + _pad * 2,
                  right: showDanger ? _thumbD + _pad * 2 : _pad,
                  child: Center(
                    child: Text(
                      showDanger ? '退出并不保存照片' : '退出并保存照片',
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: _dragT == null
                      ? const Duration(milliseconds: 160)
                      : Duration.zero,
                  left: thumbX,
                  top: _pad,
                  child: Container(
                    width: _thumbD,
                    height: _thumbD,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
