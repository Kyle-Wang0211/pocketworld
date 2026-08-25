// vio_thermal_channel.dart — 平台通道绑定(Dart 侧唯一入口)。
//
// 两端实现同一份契约:
//   MethodChannel  "pocketworld_vio_thermal"
//     start()    -> null      开始监听热/相机中断事件
//     stop()     -> null
//     snapshot() -> Map       立刻取一次当前状态(冷启动用)
//     noteVisualUpdate(Map)   可选:把一次视觉更新的 cpu/wall 耗时交给平台侧
//                             记账(iOS 用 thread_info,Android 用 /proc)
//   EventChannel   "pocketworld_vio_thermal/events"
//     Stream<Map>             热档位 / 相机中断 / headroom 变化时推一条
//
// 平台侧**不做任何档位判断**,只上报原始值;折叠与决策全在 Dart。

import 'dart:async';

import 'package:flutter/services.dart';

import 'thermal_signal.dart';

const String kVioThermalMethodChannel = 'pocketworld_vio_thermal';
const String kVioThermalEventChannel = 'pocketworld_vio_thermal/events';

class VioThermalChannel {
  VioThermalChannel({
    MethodChannel? method,
    EventChannel? events,
  })  : _method = method ?? const MethodChannel(kVioThermalMethodChannel),
        _events = events ?? const EventChannel(kVioThermalEventChannel);

  final MethodChannel _method;
  final EventChannel _events;

  /// 平台事件流。解码失败的事件被**丢弃并计数**,绝不抛到采集主流程上。
  Stream<ThermalSignal> signals() {
    return _events.receiveBroadcastStream().transform(
      StreamTransformer<dynamic, ThermalSignal>.fromHandlers(
        handleData: (dynamic event, EventSink<ThermalSignal> sink) {
          if (event is Map) {
            sink.add(decodeThermalSignal(event.cast<Object?, Object?>()));
          } else {
            _malformedEvents += 1;
          }
        },
        handleError: (Object err, StackTrace st, EventSink<ThermalSignal> sink) {
          _channelErrors += 1;
        },
      ),
    );
  }

  int _malformedEvents = 0;
  int _channelErrors = 0;
  int get malformedEvents => _malformedEvents;
  int get channelErrors => _channelErrors;

  Future<void> start() => _method.invokeMethod<void>('start');
  Future<void> stop() => _method.invokeMethod<void>('stop');

  /// 立刻取一次快照。平台不可用时返回 null,调用方按"读不到"处理,
  /// **不能**当成 nominal。
  Future<ThermalSignal?> snapshot() async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>('snapshot');
    if (raw == null) return null;
    return decodeThermalSignal(raw);
  }
}
