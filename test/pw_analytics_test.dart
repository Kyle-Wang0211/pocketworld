// 第一方统计客户端的行为契约。
// 不碰网络:注入 debugSender,SharedPreferences 用 mock。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocketworld_flutter/analytics/pw_analytics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('关闭开关 = 停收 + 清空本地队列,而不是只停发', () async {
    SharedPreferences.setMockInitialValues({
      'pw.analytics.queue': ['{"event":"x"}'],
    });
    final a = PwAnalytics.instance;
    await a.setEnabled(false);
    final p = await SharedPreferences.getInstance();
    expect(
      p.getStringList('pw.analytics.queue'),
      isNull,
      reason: '统计属非必要信息,拒绝后设备上不该留尚未上报的数据',
    );
    expect(p.getBool('pw.analytics.enabled'), isFalse);
    await a.setEnabled(true); // 复位,避免污染其他测试
  });

  test('discard 与 success 都出队;tryAgain 保留重试', () async {
    SharedPreferences.setMockInitialValues({
      'pw.analytics.enabled': true,
      'pw.analytics.queue': [
        jsonEncode({'event': 'a'}),
        jsonEncode({'event': 'b'}),
      ],
    });
    final a = PwAnalytics.instance;
    await a.setEnabled(true);
    // tryAgain:队列必须原样保留
    a.debugSender = (rows) async => SendResult.tryAgain;
    await a.debugFlush();
    var p = await SharedPreferences.getInstance();
    expect(p.getStringList('pw.analytics.queue')!.length, 2);
    // discard(4xx,数据本身有问题):必须出队,不能无限重试同一批坏数据
    a.debugSender = (rows) async => SendResult.discard;
    await a.debugFlush();
    p = await SharedPreferences.getInstance();
    expect(p.getStringList('pw.analytics.queue'), isEmpty);
    a.debugSender = null;
  });
}
