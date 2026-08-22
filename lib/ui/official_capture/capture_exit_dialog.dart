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
// [2026-08-22 用户签决,同日第二次改动] 开关**去掉绿/红,改成单色 + 开/关字样**:
//   • 开(默认)= 黑底白字「开」= 保存照片;
//   • 关        = 浅灰底黑字「关」= 不保存照片。
//   行标签问的是"是否保存照片",开/关正好是这句问话的答案,比颜色直白。
//
// ⚠️ 这条改动动了 08-09 定下的一条原则。原则原文是「颜色黑白(与设计册一致,
// 红色仅用于破坏性状态)」—— 那时破坏性状态是**靠红色**表达的。现在整颗开关
// 单色化,**破坏性信号从颜色移到了「关」这个字上**:不保存这条路不再有任何
// 红色提示,全靠字。这被认为是改进(字是明确的,颜色不是;而且这颗控件因此
// 回到了设计册的灰阶体系),但它确实是对签决原则的修改,不是漂移。
//
// [kCaptureExitDangerRed] 因此在本弹窗里**不再被使用**。常量予以保留(见其
// 文档注释),没有删除。
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
///
/// ⚠️ 2026-08-22 开关单色化之后,**本弹窗已不再使用这支红** —— 破坏性信号改由
/// 「关」字承担。常量保留而非删除:它是 08-09 签决留下的公开符号,主干里除本
/// 文件与其测试外无人 import(已 grep 核实),留着零成本,删掉则是一次没被要求
/// 的公开 API 变更。要清理请单独提。
const Color kCaptureExitDangerRed = Color(0xFFFF3B30);

/// 「关」(不保存)态的轨道浅灰。
///
/// 取自设计册 `AetherColors.border`(0xFFE4E4E4,发丝级分隔线灰)。这里写字面
/// 值而不 import design_system:`lib/ui/official_capture/` 整棵树**没有任何一个
/// 文件** import 设计册(刻意的隔离),本文件既有做法也是"写字面值 + 标注出处"。
///
/// 为什么不用更深的灰(如 `textTertiary` 0xFF9B9B9B)配白字:白字压在 #9B9B9B
/// 上对比度只有约 2.5:1,而「关」现在是破坏性动作**唯一**的信号,不能不清楚。
/// 浅灰底 + 黑字约 12:1。
const Color kCaptureExitToggleOffTrack = Color(0xFFE4E4E4);

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

  /// 塞进一个汉字之后的宽度。51 → 60:滑纽 27 + 两侧内缩 4 之外还剩 29,
  /// 「开/关」13pt 字 + 左右各 8pt 内边距 = 29,正好不压到滑纽。
  /// (这一行的余量见 393pt 布局用例 —— 加宽 9pt 之后仍然单行放得下。)
  static const double _switchW = 60;
  static const double _switchH = 31;
  static const double _wordSize = 13;
  static const double _wordPad = 8;
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
            // 单色:开 = 黑(本弹窗一路在用的那支黑,标题/取消底/确定描边同源),
            // 关 = 浅灰。深色 = 开,是单色开关的通行读法。
            color: _save ? Colors.black : kCaptureExitToggleOffTrack,
            borderRadius: BorderRadius.circular(_switchH / 2),
          ),
          child: Stack(
            children: <Widget>[
              // 字放在滑纽不在的那半边(沿用 08-09 滑轴的老做法)。
              AnimatedAlign(
                duration: _toggleDuration,
                curve: _toggleCurve,
                alignment: _save ? Alignment.centerLeft : Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _wordPad),
                  child: Text(
                    _save ? '开' : '关',
                    key: const ValueKey<String>('capture-exit-save-word'),
                    maxLines: 1,
                    // 这个字是"要不要保存"唯一的文字答案,不允许被系统字号
                    // 放大挤变形 —— 它在一颗定宽胶囊里。
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: _save ? Colors.white : Colors.black,
                      fontSize: _wordSize,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
              AnimatedAlign(
                duration: _toggleDuration,
                curve: _toggleCurve,
                alignment: _save
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(_knobInset),
                  child: AnimatedContainer(
                    duration: _toggleDuration,
                    curve: _toggleCurve,
                    // 有 key 才能在测试里量到滑纽的**真实位置**:轨道深浅、
                    // 滑纽位置、开/关字样,三个信号都必须钉住。
                    key: const ValueKey<String>('capture-exit-save-knob'),
                    width: _knobD,
                    height: _knobD,
                    decoration: BoxDecoration(
                      // 滑纽跟着轨道反相,两个状态都是高对比:白纽压黑轨,
                      // 黑纽压浅灰轨。白纽压 #E4E4E4 只有 1.2:1,看不见。
                      color: _save ? Colors.white : Colors.black,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
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
