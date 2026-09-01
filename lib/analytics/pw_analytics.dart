// 第一方统计(自建埋点)。
// =====================================================================
// 结构改写自 Aptabase Flutter SDK(github.com/aptabase/aptabase_flutter,
// MIT License)—— 产品方针"优先成熟开源,复刻不自研"。保留其四个核心设计:
//   · SharedPreferences 持久化事件队列(掉线/杀进程不丢,重启续传)
//   · 定时冲刷 + AppLifecycleListener onInactive 冲刷(退后台前清账)
//   · 会话 id:1 小时无活动即轮换
//   · 发送三态 success / discard(4xx 丢弃) / tryAgain(5xx/网络 保留重试)
// 改掉的部分:
//   · 上报目的地从 Aptabase 云换成**我们自己的库**(PostgREST 直插
//     analytics_events 表,RLS 只许本人插入)—— 零第三方,不触碰隐私政策
//     "无第三方SDK/不跟踪"两句;
//   · 增加 opt-out(设置→帮助改进产品),关闭即停收并清空本地队列 ——
//     统计属非必要信息,监管口径下必须可拒绝;
//   · 只在登录后收集:登录墙即同意门,同意(注册)之前零统计出境。
//
// 🔴 与隐私政策第一章(五)逐句对齐:收集项、期限(服务端 180 天清扫)、
//    可关闭、不含作品内容。改这里必改政策,反之亦然
//    (test/legal_docs_public_test.dart 钉住关键词)。
//
// 埋点接入方式:代码埋点(手动 track)。不做全埋点/无埋点 —— 那需要
// AOP 级别的框架侵入,且会把大量未经设计的界面数据收进来,与最小必要冲突。
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, Supabase;

/// 发送结果三态(Aptabase 同款语义)。测试注入口需要引用,故公共。
enum SendResult { success, discard, tryAgain }

class PwAnalytics {
  PwAnalytics._();
  static final PwAnalytics instance = PwAnalytics._();

  static const _prefEnabled = 'pw.analytics.enabled';
  static const _prefQueue = 'pw.analytics.queue';
  static const _sessionTimeout = Duration(hours: 1);
  static const _tick = Duration(seconds: 30);
  static const _batch = 25;
  // 队列硬顶:断网时最多攒 500 条,再来就丢最旧的。
  // 统计丢一点无所谓,把用户磁盘/内存吃满才是事故。
  static const _queueCap = 500;
  // 每会话错误事件上限,防异常风暴刷爆队列。
  static const _errorCapPerSession = 20;

  static const String _appVersion = String.fromEnvironment(
    'PW_APP_VERSION',
    defaultValue: 'dev',
  );

  // ⚠️ 不缓存 SharedPreferences 实例:setMockInitialValues 会重置底层
  //    存储,缓存的旧实例读到的是旧 map(测试里踩过)。getInstance 自身
  //    有单例缓存,现取没有额外成本。
  bool _inited = false;
  bool _enabled = true;
  Timer? _timer;
  // 持有引用防被 GC;App 全生命周期存活,不需要 dispose 路径。
  // ignore: unused_field
  AppLifecycleListener? _lifecycle;
  bool _flushing = false;
  String _sessionId = _newSessionId();
  DateTime _lastTouch = DateTime.now().toUtc();
  int _errorsThisSession = 0;

  /// 测试注入口:替换真实的 PostgREST 发送。
  @visibleForTesting
  Future<SendResult> Function(List<Map<String, dynamic>> rows)? debugSender;

  bool get enabled => _enabled;

  /// 幂等初始化。放在 CurrentUser.bootstrap 顶部调用:
  /// init 本身不发事件;track 在未登录时是 no-op。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool(_prefEnabled) ?? true;
    _lifecycle = AppLifecycleListener(
      onInactive: () => unawaited(_flush('inactive')),
      onResume: _startTimer,
    );
    _startTimer();
    track('app_open');
  }

  /// 设置页开关。关闭 = 停收 + 清空本地未发队列(不是只停发)。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_prefEnabled, value);
    if (!value) await p.remove(_prefQueue);
    track('analytics_toggled', {'enabled': value});
  }

  /// 记一个事件。未登录/已关闭 ⇒ 静默 no-op,永不抛异常 ——
  /// 统计的任何失败都不允许影响业务路径。
  ///
  /// 🔴 事件形状必须固定(下面的 row 永远包含全部键):PostgREST 批量插入
  ///    要求同批所有行键集合一致(PGRST102 "All object keys must match",
  ///    2026-08-24 生产实测)。给 row 加可选键 = 让混合批次整批 400。
  void track(String event, [Map<String, Object?>? props]) {
    try {
      if (!_enabled) return;
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final row = <String, dynamic>{
        'event': event,
        'session_id': _evalSessionId(),
        'props': props ?? const {},
        'app_version': _appVersion,
        'os_version':
            '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        'client_ts': DateTime.now().toUtc().toIso8601String(),
      };
      unawaited(_enqueue(jsonEncode(row)));
    } catch (_) {
      // 吞掉:见方法注释。
    }
  }

  /// 错误/崩溃钩子。链式接管 FlutterError.onError 与
  /// PlatformDispatcher.onError,原 handler 照常执行。
  /// 只收错误摘要与截断堆栈,绝不含作品内容或个人资料。
  void installErrorHandlers() {
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _trackError(details.exceptionAsString(), details.stack, fatal: false);
      prevFlutter?.call(details);
    };
    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _trackError(error.toString(), stack, fatal: true);
      return prevPlatform?.call(error, stack) ?? false;
    };
  }

  void _trackError(String message, StackTrace? stack, {required bool fatal}) {
    if (_errorsThisSession >= _errorCapPerSession) return;
    _errorsThisSession++;
    track('app_error', {
      'message': message.length > 300 ? message.substring(0, 300) : message,
      'stack': (stack?.toString() ?? '').split('\n').take(12).join('\n'),
      'fatal': fatal,
    });
  }

  // ── 队列与冲刷(Aptabase 的 tick 模型)─────────────────────────────
  Future<void> _enqueue(String json) async {
    final p = await SharedPreferences.getInstance();
    final q = p.getStringList(_prefQueue) ?? <String>[];
    q.add(json);
    while (q.length > _queueCap) {
      q.removeAt(0);
    }
    await p.setStringList(_prefQueue, q);
  }

  void _startTimer() {
    _timer ??= Timer.periodic(_tick, (_) => unawaited(_flush('timer')));
  }

  @visibleForTesting
  Future<void> debugFlush() => _flush('test');

  Future<void> _flush(String reason) async {
    if (_flushing) return;
    _flushing = true;
    try {
      if (!_enabled) return;
      final p = await SharedPreferences.getInstance();
      // ⚠️ Supabase.instance 在未 initialize 时(单测环境)会抛 ——
      //    debugSender 模式下不许碰它。
      String? uid;
      if (debugSender == null) {
        uid = Supabase.instance.client.auth.currentUser?.id;
        if (uid == null) return;
      }
      while (true) {
        final q = p.getStringList(_prefQueue) ?? <String>[];
        if (q.isEmpty) return;
        final take = q.length < _batch ? q.length : _batch;
        final rows = q.take(take).map((e) {
          final m = jsonDecode(e) as Map<String, dynamic>;
          if (uid != null) m['user_id'] = uid;
          return m;
        }).toList();
        final result = await _send(rows);
        if (result == SendResult.tryAgain) return; // 留着下轮再试
        // success 或 discard 都出队。
        await p.setStringList(_prefQueue, q.sublist(take));
        if (take < _batch) return;
      }
    } catch (_) {
      // 吞掉:统计失败不打扰任何人。
    } finally {
      _flushing = false;
    }
  }

  Future<SendResult> _send(List<Map<String, dynamic>> rows) async {
    final custom = debugSender;
    if (custom != null) return custom(rows);
    try {
      await Supabase.instance.client.from('analytics_events').insert(rows);
      return SendResult.success;
    } on PostgrestException catch (e) {
      // 4xx(RLS 拒绝/约束不符)= 数据本身有问题,重试无意义 ⇒ 丢弃;
      // 其余(网络/5xx)保留重试。code 可能是 SQLSTATE 字符串。
      final code = int.tryParse(e.code ?? '');
      if (code != null && code >= 500) return SendResult.tryAgain;
      return SendResult.discard;
    } catch (_) {
      return SendResult.tryAgain;
    }
  }

  // ── 会话(1 小时无活动轮换,Aptabase 同款)──────────────────────────
  String _evalSessionId() {
    final now = DateTime.now().toUtc();
    if (now.difference(_lastTouch) > _sessionTimeout) {
      _sessionId = _newSessionId();
      _errorsThisSession = 0;
    }
    _lastTouch = now;
    return _sessionId;
  }

  static String _newSessionId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(22, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
