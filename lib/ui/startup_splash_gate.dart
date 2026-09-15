// startup_splash_gate.dart — 「启动动画已经放完了」这一个布尔。
//
// 🔴 存在理由(实测,不是设计洁癖):启动期有几件重活既不显示也不紧急,
// 却会把平台线程整段堵住,正好压在球→线→开门那 1290ms 上。155 的账里
// +2293→+2944ms **一帧都没有** —— 球僵在那儿 651ms。
//
// 这是一条**单向**接缝:浮层说"我放完了",别人听。听的人不认识浮层、
// 浮层也不认识听的人,不构成互相耦合。
library;

import 'dart:async';

class StartupSplashGate {
  StartupSplashGate._();
  static final StartupSplashGate instance = StartupSplashGate._();

  Completer<void> _completer = Completer<void>();
  bool _done = false;

  bool get isDone => _done;

  /// 放完之后才 complete。重复调用无害。
  Future<void> get whenDone => _completer.future;

  void markDone() {
    if (_done) return;
    _done = true;
    if (!_completer.isCompleted) _completer.complete();
  }

  /// 每次冷启动重来一遍(测试里也用)。
  void reset() {
    if (!_done && !_completer.isCompleted) return; // 还没放完,别换掉在等的人
    _done = false;
    _completer = Completer<void>();
  }
}
