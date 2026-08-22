// capture_exit_dialog.dart — 拍摄中退出的确认弹窗(黑白 + 开关)。
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
//
// [2026-08-22 用户签决,本次改版] 上面那版滑轴的问题是"滑轴"这个控件本身要教:
// 用户看不出滑动只切换、点击才执行。改成一条**带标签的开关**,语义直接写在
// 标签上,执行动作交给下面两颗按钮:
//   • 标题"退出拍摄?"**居中**(原来左对齐);
//   • 第一行 = "是否保存照片,方便下次补拍" + 右侧小开关
//       开(默认)= 绿(iOS systemGreen)→ 退出并保存照片;
//       关        = 红(iOS systemRed,与原滑轴破坏态同一支)→ 退出并不保存;
//   • 第二行 = "确定"(白底黑边黑字)/ "取消"(黑底白字),取代原"继续拍摄"。
//     视觉权重是**故意倒置**的 —— 实心黑的那颗是"取消",因为安全动作才该是
//     主导项(用户明确要求,不是笔误)。
//   • 点弹窗外任意处 = 仍然自动返回拍摄(barrierDismissible 不变)。
//
// ⚠️ 保留自 08-09 的安全性质:破坏性出路仍需**两个刻意动作**。原来是
// "滑过去 + 点文字区",现在是"拨开关 + 点确定" —— 默认态(开关绿)下任何
// **单次**手势都到不了 discardExit:点确定 = saveExit,点取消/点外面 = null。
import 'package:flutter/material.dart';

/// 弹窗结果。null(点外面/取消)= 回拍摄。
enum CaptureExitChoice {
  /// 退出并保存照片:照片进草稿(未完成态,可断点续跑),不丢任何数据。
  saveExit,

  /// 退出并不保存照片:丢弃本次素材(原有"退出并丢弃"的算法)。
  discardExit,
}

/// 破坏性红(与草稿卡"未完成"胶囊同一支 iOS systemRed)。
const Color kCaptureExitDangerRed = Color(0xFFFF3B30);

/// 保存态绿。取自 scan_record_cell.dart 的"完成"胶囊(iOS systemGreen)——
/// 那里的"未完成"胶囊正是本文件的 [kCaptureExitDangerRed],红绿本来就是
/// 同一对签决过的系统色,不另造一支。
///
/// (设计册 `AetherColors.success` 是 0xFF111111 近黑 —— 那是刻意的灰阶
/// "成功",不能拿来当"绿";`inspCustomizable` 的绿是开发期 inspector 覆盖层
/// 专用,也不进产品 UI。)
const Color kCaptureExitSaveGreen = Color(0xFF34C759);

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
  /// 开关状态。true = 保存照片(默认,绿),false = 不保存(红)。
  ///
  /// 默认保存:与 08-09 那版"滑块默认停在左侧 = 退出并保存"一致,也和
  /// 文案"方便下次补拍"一致。
  bool _save = true;

  /// 开关滑行动画。**沿用 ar_capture_page 里模式开关那一档**(180ms /
  /// easeOut)—— 同一条拍摄链路上的开关是同一种手感,不为这一颗另起数字。
  static const Duration _toggleDuration = Duration(milliseconds: 180);
  static const Curve _toggleCurve = Curves.easeOut;

  static const double _switchW = 51;
  static const double _switchH = 31;
  static const double _knobInset = 2;
  static const double _knobD = _switchH - _knobInset * 2;

  /// 当前是否会保存照片(true = saveExit)。测试用:取代旧的 `debugRight`
  /// (旧值语义是"滑块在右 = 不保存",与本值正好相反)。
  @visibleForTesting
  bool get debugSave => _save;

  void _confirm() {
    Navigator.of(
      context,
    ).pop(_save ? CaptureExitChoice.saveExit : CaptureExitChoice.discardExit);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '退出拍摄？',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            _buildSaveRow(),
            const SizedBox(height: 20),
            _buildButtons(),
          ],
        ),
      ),
    );
  }

  /// "是否保存照片,方便下次补拍" + 右侧小开关。
  ///
  /// 标签用 [Expanded] 兜住:393pt 屏上这一行本来就紧(弹窗内容宽 ~273pt),
  /// 一旦系统字号放大,文字**折行**而不是把开关挤出屏幕。
  Widget _buildSaveRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Expanded(
          child: Text(
            '是否保存照片，方便下次补拍',
            style: TextStyle(
              color: Colors.black,
              fontSize: 15,
              height: 1.3,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 12),
        _buildSwitch(),
      ],
    );
  }

  Widget _buildSwitch() {
    return Semantics(
      toggled: _save,
      label: '保存照片',
      child: GestureDetector(
        key: const ValueKey<String>('capture-exit-save-toggle'),
        behavior: HitTestBehavior.opaque,
        // 拨开关**只切换、不执行** —— 执行永远只发生在"确定"上。
        onTap: () => setState(() => _save = !_save),
        child: AnimatedContainer(
          duration: _toggleDuration,
          curve: _toggleCurve,
          width: _switchW,
          height: _switchH,
          decoration: BoxDecoration(
            color: _save ? kCaptureExitSaveGreen : kCaptureExitDangerRed,
            borderRadius: BorderRadius.circular(_switchH / 2),
          ),
          child: AnimatedAlign(
            duration: _toggleDuration,
            curve: _toggleCurve,
            alignment: _save ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(_knobInset),
              child: Container(
                // 有 key 才能在测试里量到滑纽的**真实位置**:轨道颜色和滑纽
                // 位置是这颗开关仅有的两个信号,两个都必须钉住。
                key: const ValueKey<String>('capture-exit-save-knob'),
                width: _knobD,
                height: _knobD,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "确定"(白底黑边黑字)/ "取消"(黑底白字)。
  Widget _buildButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            key: const ValueKey<String>('capture-exit-confirm'),
            onPressed: _confirm,
            style: OutlinedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              side: const BorderSide(color: Colors.black, width: 1.5),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: const Text(
              '确定',
              maxLines: 1,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            key: const ValueKey<String>('capture-exit-cancel'),
            onPressed: () => Navigator.of(context).pop(null),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: const Text(
              '取消',
              maxLines: 1,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
