// Aether3D PocketWorld — Flutter entry point.
//
// Responsibilities (deliberately narrow so UI iterations stay in lib/ui/
// and domain code lives in its own lib/ folder per module):
//   • Firebase init + AuthService selection (Firebase vs Mock fallback)
//   • CurrentUser ChangeNotifier instantiation + bootstrap
//   • AuthGate: bootstrapping → AuthRootView | AppShell
//   • Dawn texture + gesture lifecycle (same as before; only runs once
//     the user is signed in so the GPU isn't wasted on the auth screen)
//
// Modules:
//   lib/auth/             — protocol + Firebase + Mock + CurrentUser + AuthScope
//   lib/pipeline/         — RemoteB1Client + BackgroundUploadBroker Dart port
//   lib/quality/          — GuidanceEngine Dart port + QualityMetrics glue
//   lib/dome/             — arcball AR pose abstraction + sphere wedge renderer
//   lib/ui/               — design tokens + splash + shell + pages
//   lib/ui/auth/          — AuthRootView + EmailSignIn + PhoneSignIn + shared widgets

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_scope.dart';
import 'auth/cold_start_session_gate.dart';
import 'auth/current_user.dart';
import 'auth/unavailable_auth_service.dart';
import 'auth/secure_session_storage.dart';
import 'auth/supabase_auth_service.dart';
import 'config/endpoint_config.dart';
import 'i18n/locale_notifier.dart';
import 'l10n/app_localizations.dart';
import 'lifecycle_observer.dart';
import 'object_transform.dart';
import 'official_aether_sfm_ffi.dart' show AetherEnvFile;
import 'official_capture/b1_gate_runner.dart';
import 'official_capture/encoder_probe.dart';
import 'official_capture/photo_archive_runtime.dart';
import 'official_capture/telemetry_writer.dart' as official_telemetry;
import 'official_util/device_log.dart' as official_device_log;
import 'orbit_controls.dart';
import 'ui/app_shell.dart';
import 'ui/auth/auth_root_view.dart';
import 'ui/design_system.dart';
import 'ui/splash_overlay.dart';
import 'util/device_log.dart';

/// Global ScaffoldMessenger key. Wired onto [MaterialApp.scaffoldMessengerKey]
/// so any code path can show a snackbar that survives:
///   • showModalBottomSheet's pop animation (locally-scoped messengers
///     pause snackbar rendering until the sheet's exit transition
///     finishes — which makes their 3-4 s timer burn while invisible
///     and the snackbar is missed entirely);
///   • widget-tree unmounts mid-await (a rebuilt route would otherwise
///     leave the snackbar attached to a context that's gone, silently
///     swallowing the call).
///
/// Use `rootScaffoldMessengerKey.currentState?.showSnackBar(...)` from
/// any callback regardless of widget mounting state.
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  // SMOKE LOG: if you don't see this print in Xcode console, Dart
  // main never got invoked by FlutterEngine — problem is above us
  // (iOS 26 + Flutter JIT handshake, plugin register blocking, etc).
  // If you see it but no UI, problem is below us (widget tree build).
  // ignore: avoid_print
  print('[AET-SMOKE] Dart main entered');

  FlutterError.onError = (details) {
    // ignore: avoid_print
    print('[FlutterError] ${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };

  // CRITICAL: ensureInitialized() AND runApp() MUST be called in the
  // SAME zone, otherwise Flutter emits "Zone mismatch" and
  // zone-specific configuration (error handlers, async tracking)
  // becomes inconsistent. Both live inside the runZonedGuarded
  // callback below.
  //
  // Defense-in-depth: any setup exception routes to the fallback
  // handler and the app still comes up (with mock auth) so the user
  // sees the sign-in page instead of a blank crash.
  runZonedGuarded<Future<void>>(
    () async {
      // ignore: avoid_print
      print('[AET-SMOKE] inside runZonedGuarded');
      WidgetsFlutterBinding.ensureInitialized();
      await officialArchiveBackgroundRuntime.initialize();
      // Release-visible container-file log (Documents/pw_device_log.txt) —
      // print/debugPrint are invisible in release builds on device.
      unawaited(DeviceLog.init());
      // The production capture runtime owns a release-visible capture log.
      // [2026-08-10 时序修正] 这里改成 await:EnvFile 的"applied"收据原先在
      // 日志文件打开**之前**写,release 下只进不可见的 print —— 实机核验时
      // 拿不到任何生效证据(08-10 自然停止 A/B 实测踩中)。先开日志再应用
      // env,启动路径仍在任何拍摄/进 native 之前。
      await official_device_log.DeviceLog.init();
      // [ENV-FILE 2026-08-10] 诊断 env 直通:必须 await(在任何拍摄/进
      // native 之前生效);文件不存在=零行为。应用结果记进 device log 留证。
      try {
        final docs = await getApplicationDocumentsDirectory();
        final applied = await AetherEnvFile.applyFrom(docs.path);
        if (applied.isNotEmpty) {
          official_device_log.DeviceLog.log('EnvFile', 'applied: $applied');
        }
      } catch (_) {}
      // Events queued before this completes are flushed by the writer.
      unawaited(() async {
        try {
          final dir = await getApplicationDocumentsDirectory();
          await official_telemetry.TelemetryWriter.instance.init(
            '${dir.path}/telemetry_official_dart.jsonl',
          );
          official_telemetry.TelemetryWriter.instance.event(
            'official_dart_session',
          );
        } catch (_) {}
      }());
      // ignore: avoid_print
      print('[AET-SMOKE] ensureInitialized done, about to runApp');

      // Plan G W2 全本地 (2026-05-16): background_downloader init removed
      // along with the rest of the cloud upload chain. Captures live
      // entirely on-device — no background uploads to resume after force-
      // quit, so the persistent task DB / TaskStatusUpdate listener serve
      // no purpose. The `background_downloader` package can also be
      // dropped from pubspec.yaml at the next dependency sweep.

      // Launch the app with a mock auth service so runApp fires on the
      // very next microtask and the splash paints immediately. Firebase
      // is initialized in the background and swapped into CurrentUser
      // once it's up (or after a 10-second timeout fallback to mock).
      // [2026-09-07 用户裁决] 启动期不再用 Mock 登录服务占位:占位服务是
      // "显式不可用",任何登录动作都报 providerUnavailable;后端就绪后再换成
      // 真实认证。初始化失败/超时 ⇒ 不可用态 + 重试,不回退假登录。
      final currentUser = CurrentUser(service: const UnavailableAuthService());
      final localeNotifier = LocaleNotifier();
      unawaited(localeNotifier.bootstrap());
      runApp(
        PocketWorldApp(
          currentUser: currentUser,
          localeNotifier: localeNotifier,
        ),
      );
      _appCurrentUser = currentUser;
      // ignore: avoid_print
      print('[AET-SMOKE] runApp returned');
      // Did Flutter actually paint the first frame?
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // ignore: avoid_print
        print('[AET-SMOKE] first frame PAINTED');
        unawaited(() async {
          try {
            final documents = await getApplicationDocumentsDirectory();
            await photoArchiveCoordinator.discoverUnderDocuments(documents);
          } catch (_) {
            // Startup archive recovery is best effort and fails closed.
          }
        }());
        // B1 验收门(文件触发,开发侧 devicectl 投放请求;无文件=零行为)。
        unawaited(() async {
          try {
            final documents = await getApplicationDocumentsDirectory();
            await maybeRunB1Gate(documents.path);
          } catch (_) {}
        }());
        // 编码器旋钮探针(同款文件触发;无文件=零行为)。
        unawaited(() async {
          try {
            final documents = await getApplicationDocumentsDirectory();
            await maybeRunEncoderProbe(documents.path);
          } catch (_) {}
        }());
      });
      WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
        // ignore: avoid_print
        print('[AET-SMOKE] first frame RASTERIZED');
      });

      currentUser.retryInit = () =>
          _initAuthBackend(currentUser, localeNotifier);
      unawaited(_initAuthBackend(currentUser, localeNotifier));
    },
    (error, stack) {
      // ignore: avoid_print
      print('[main.runZonedGuarded] uncaught: $error\n$stack');
      // [2026-09-07 用户裁决] 未捕获异常只记日志,**绝不**用假登录服务重新
      // runApp(此前每个异常都会把整个 app 换成 Mock 版:未命名(18) 拍摄期间
      // 异常风暴 ⇒ 用户在 Mock 登录页里输了真账号)。设备日志留原文,离线可查。
      try {
        final text = '$error\n$stack';
        DeviceLog.log(
          'Uncaught',
          text.length > 4000 ? text.substring(0, 4000) : text,
        );
      } catch (_) {}
      if (_appCurrentUser == null) {
        // 还没 runApp 就炸了:用真实(不可用态)的 app 起来,让用户看到失败与重试。
        try {
          WidgetsFlutterBinding.ensureInitialized();
          final cu = CurrentUser(service: const UnavailableAuthService())
            ..markServiceUnavailable('startup failed before runApp: $error');
          _appCurrentUser = cu;
          runApp(
            PocketWorldApp(currentUser: cu, localeNotifier: LocaleNotifier()),
          );
        } catch (e) {
          // ignore: avoid_print
          print('[main] fallback runApp also failed: $e');
        }
      }
    },
  );
}

/// runApp 过的 CurrentUser(只用于未捕获异常兜底判断"app 起来了没有")。
CurrentUser? _appCurrentUser;

const Color _aetherColdStartBackground = AetherColors.bg;

Future<void>? _supabaseInit;

Future<void> _startSupabase(String supabaseUrl, String supabaseAnonKey) {
  late final Future<void> f;
  f =
      Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
        debug: false,
        // Keychain instead of the default plaintext UserDefaults. The
        // default leaves the long-lived refresh_token readable in the
        // preferences plist and carries it into unencrypted backups;
        // see lib/auth/secure_session_storage.dart for why the key
        // derivation and accessibility level are what they are.
        // initialize() performs the one-time migration before
        // recoverSession() runs, so existing sessions survive.
        authOptions: FlutterAuthClientOptions(
          localStorage: SecureSessionStorage(supabaseUrl: supabaseUrl),
        ),
      ).then<void>(
        (_) {},
        onError: (Object e, StackTrace st) {
          if (identical(_supabaseInit, f)) _supabaseInit = null;
          DeviceLog.log('AuthStartup', 'Supabase.initialize error: $e');
          throw e;
        },
      );
  // 超时分支不再等它;它之后若失败已在上面记日志,不要再冒成未捕获异常。
  f.ignore();
  return f;
}

/// 登录后端初始化(解析后端地址 → Supabase.initialize → 冷启动会话门 →
/// swapService → bootstrap)。启动时调一次;失败进入不可用态,UI 的"重试"
/// 通过 [CurrentUser.retryInit] 再调它。绝不回退到假登录。
Future<void> _initAuthBackend(
  CurrentUser currentUser,
  LocaleNotifier localeNotifier,
) async {
  try {
    // Backend address is resolved at RUNTIME — see
    // lib/config/endpoint_config.dart. It used to be read straight from
    // `String.fromEnvironment` here, but `--dart-define` does not reach
    // this project's iOS xcconfig chain (verified on device
    // 2026-08-09), so the defaults were the shipped values: the backend
    // host was effectively compiled into the binary, and moving it
    // meant cutting a release and waiting for adoption. The resolver
    // falls back to those same constants, so with no config endpoint
    // set this is byte-for-byte the previous behaviour.
    //
    // The anon key is intentionally public — RLS policies on each
    // table do the actual access control.
    final endpoint = await EndpointConfigResolver.resolve();
    debugPrint('[main] backend endpoint resolved: $endpoint');
    final supabaseUrl = endpoint.supabaseUrl;
    final supabaseAnonKey = endpoint.supabaseAnonKey;
    const initTimeout = Duration(seconds: 10);
    bool supabaseReady = false;
    try {
      // 重试时复用仍在途的 initialize(超时只是我们不再等,底层还在跑);
      // 只有它真的失败了才允许下一次重试重新发起。
      final inflight = _supabaseInit ??= _startSupabase(
        supabaseUrl,
        supabaseAnonKey,
      );
      await inflight.timeout(initTimeout);
      supabaseReady = true;
    } catch (e) {
      DeviceLog.log('AuthStartup', 'Supabase.initialize failed/timeout: $e');
      currentUser.markServiceUnavailable('Supabase.initialize: $e');
      return;
    }
    if (supabaseReady) {
      final auth = Supabase.instance.client.auth;
      final restoredSession = auth.currentSession;
      final gateResult = await waitForColdStartSession(
        hasSession: restoredSession != null,
        isExpired: restoredSession?.isExpired ?? false,
        authEvents: auth.onAuthStateChange.map((state) {
          return switch (state.event) {
            AuthChangeEvent.tokenRefreshed => ColdStartAuthEvent.tokenRefreshed,
            AuthChangeEvent.signedOut => ColdStartAuthEvent.signedOut,
            _ => ColdStartAuthEvent.other,
          };
        }),
        fallbackRefresh: () async {
          await auth.refreshSession();
        },
      );
      DeviceLog.log('AuthStartup', 'session gate=$gateResult');
      // ignore: avoid_print
      print(
        '[AUTH-DEBUG] Supabase.initialize done. '
        'currentSession exists: '
        '${Supabase.instance.client.auth.currentSession != null} '
        'currentUser: '
        '${Supabase.instance.client.auth.currentUser?.email ?? "null"}',
      );
      currentUser.swapService(
        SupabaseAuthServiceImpl(localeNotifier: localeNotifier),
      );
      await currentUser.bootstrap();
    }
  } catch (e, st) {
    DeviceLog.log('AuthStartup', 'init failed: $e\n$st');
    currentUser.markServiceUnavailable('init: $e');
  }
}

class PocketWorldApp extends StatelessWidget {
  final CurrentUser currentUser;
  final LocaleNotifier localeNotifier;

  const PocketWorldApp({
    super.key,
    required this.currentUser,
    required this.localeNotifier,
  });

  @override
  Widget build(BuildContext context) {
    return LocaleScope(
      notifier: localeNotifier,
      child: AnimatedBuilder(
        animation: localeNotifier,
        builder: (context, _) {
          return MaterialApp(
            title: 'PocketWorld',
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: rootScaffoldMessengerKey,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: AetherColors.primary,
                brightness: Brightness.light,
              ),
              scaffoldBackgroundColor: _aetherColdStartBackground,
              canvasColor: _aetherColdStartBackground,
              useMaterial3: true,
            ),
            locale: localeNotifier.locale,
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const _AuthGate(),
            // AuthScope wraps the *route content* via builder rather than
            // sitting inside `home`. Why: `home` is only the FIRST route on
            // the Navigator. When MePage does `Navigator.push(MaterialPageRoute(
            // builder: (_) => MeSettingsPage()))`, the pushed route lives
            // as a sibling of the home route inside the Navigator's overlay
            // — its BuildContext does NOT walk up through `home`'s subtree,
            // so `context.getInheritedWidgetOfExactType<AuthScope>()` from
            // MeSettingsPage's button used to come back null and the
            // `notifier!` assertion in AuthScope.read crashed the sign-out
            // gesture (see crash 2026-04-30 in the log:
            // `AuthScope.read … _SignOutButton.build`). The `builder`
            // callback is invoked for every route MaterialApp shows, so
            // wrapping `child` here makes AuthScope available to home AND
            // every pushed route uniformly.
            builder: (context, child) =>
                AuthScope(currentUser: currentUser, child: child!),
          );
        },
      ),
    );
  }
}

/// Routes between the three CurrentUser states:
///   bootstrapping → animated splash
///   signedOut     → AuthRootView (email / phone sign-in)
///   signedIn      → HomeScreen (vault + me + 3D texture)
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _splashMinElapsed = false;
  Timer? _splashMinTimer;
  // Tracks the previous CurrentUserState so we can detect a signedIn →
  // signedOut transition and tear down any pushed routes that were
  // sitting on top of HomeScreen (MyWorkDetailPage, MeSettingsPage,
  // …). Without this, swiping back from a stale detail page after a
  // background-kill / cold-start session-restore race reveals the auth
  // page underneath, which is jarring.
  bool _wasSignedIn = false;

  @override
  void initState() {
    super.initState();
    // Minimum splash duration — avoids a jarring flicker when bootstrap
    // completes in a few ms (e.g. mock service / cached user).
    _splashMinTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _splashMinElapsed = true);
    });
  }

  @override
  void dispose() {
    _splashMinTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthScope.of(context);
    final state = user.state;

    // signedIn → signedOut transition: pop any routes pushed on top of
    // home so the user isn't left with a stale detail / settings page
    // hovering over AuthRootView. addPostFrameCallback so this runs
    // outside of build() (Navigator.popUntil during build asserts).
    if (_wasSignedIn && state is CurrentUserSignedOut) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final navigator = Navigator.maybeOf(context);
        navigator?.popUntil((r) => r.isFirst);
      });
    }
    _wasSignedIn = state is CurrentUserSignedIn;

    // During bootstrap OR until min-splash elapsed, show the splash.
    final splashVisible =
        state is CurrentUserBootstrapping || !_splashMinElapsed;

    Widget body;
    if (state is CurrentUserSignedIn) {
      body = const HomeScreen();
    } else if (state is CurrentUserSignedOut) {
      body = AuthRootView(currentUser: user);
    } else if (state is CurrentUserServiceUnavailable) {
      body = _ServiceUnavailableView(currentUser: user, reason: state.reason);
    } else {
      body = const SizedBox.expand();
    }

    return Stack(
      children: [
        body,
        Positioned.fill(
          child: AetherSplashOverlay(
            visible: splashVisible,
            progressMessage: _bootstrapMessage(context, state),
          ),
        ),
      ],
    );
  }

  String _bootstrapMessage(BuildContext context, CurrentUserState state) {
    final l = AppL10n.of(context);
    if (state is CurrentUserBootstrapping) return l.splashRestoringSession;
    if (state is CurrentUserSignedOut) return l.splashPreparingSignIn;
    if (state is CurrentUserServiceUnavailable) return l.authServiceUnavailable;
    return l.splashWaking3DEngine;
  }
}

/// 登录后端不可用:显示失败与重试,不显示登录表单(表单背后没有真服务)。
class _ServiceUnavailableView extends StatelessWidget {
  const _ServiceUnavailableView({
    required this.currentUser,
    required this.reason,
  });

  final CurrentUser currentUser;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.authServiceUnavailable,
                  textAlign: TextAlign.center,
                  style: AetherTextStyles.body,
                ),
                const SizedBox(height: 12),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: AetherTextStyles.caption,
                ),
                const SizedBox(height: 24),
                AnimatedBuilder(
                  animation: currentUser,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        onPressed: currentUser.isRetryingInit
                            ? null
                            : () => unawaited(currentUser.retryServiceInit()),
                        child: Text(l.authRetry),
                      ),
                      if (currentUser.nextAutoRetryAt != null ||
                          currentUser.isRetryingInit) ...[
                        const SizedBox(height: 12),
                        Text(
                          l.authAutoRetrying,
                          textAlign: TextAlign.center,
                          style: AetherTextStyles.caption,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _channel = MethodChannel('aether_texture');
  int? _textureId;
  String? _textureError;
  bool _isRetrying = false;

  String? _meshStatus = 'warming up renderer...';
  bool _meshStatusBusy = true;
  bool _meshStatusError = false;
  Timer? _meshStatusHideTimer;

  static const _splashMinDurationMs = 1200;
  static const _splashMaxDurationMs = 20000;
  bool _splashMinElapsed = false;
  bool _splashForceHidden = false;
  Timer? _splashMinTimer;
  Timer? _splashMaxTimer;

  final OrbitControls _orbit = OrbitControls();
  final ObjectTransform _object = ObjectTransform();
  LifecycleObserver? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = LifecycleObserver(
      orbit: _orbit,
      obj: _object,
      onStateChanged: () {
        if (!mounted) return;
        setState(() {});
        _pushMatrices();
      },
    );
    _splashMinTimer = Timer(
      const Duration(milliseconds: _splashMinDurationMs),
      () {
        if (!mounted) return;
        setState(() => _splashMinElapsed = true);
      },
    );
    _splashMaxTimer = Timer(
      const Duration(milliseconds: _splashMaxDurationMs),
      () {
        if (!mounted) return;
        setState(() => _splashForceHidden = true);
      },
    );
    _requestTexture();
  }

  bool get _splashVisible {
    if (_splashForceHidden) return false;
    if (!_splashMinElapsed) return true;
    final rendererReady = _textureId != null;
    final meshSettled = !_meshStatusBusy || _meshStatusError;
    return !(rendererReady && meshSettled);
  }

  String _splashMessage(BuildContext context) {
    final l = AppL10n.of(context);
    if (_textureError != null) return l.splashRendererUnavailable;
    if (_textureId == null) return l.splashWaking3DEngine;
    if (_meshStatusBusy) return l.splashWaking3DEngine;
    return l.splashWaking3DEngine;
  }

  Future<void> _requestTexture({bool isManualRetry = false}) async {
    if (_isRetrying) return;
    setState(() {
      _isRetrying = true;
      _textureError = null;
      if (isManualRetry) _textureId = null;
      _meshStatus = 'warming up renderer...';
      _meshStatusBusy = true;
      _meshStatusError = false;
    });
    try {
      final id = await _channel.invokeMethod<int>('createSharedNativeTexture');
      if (!mounted) return;
      setState(() {
        _textureId = id;
        _isRetrying = false;
        _meshStatus = 'loading DamagedHelmet.glb...';
        _meshStatusBusy = true;
        _meshStatusError = false;
      });
      if (id != null) {
        _pushMatrices();
        unawaited(_loadDefaultGlb(id));
      }
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _textureError =
            'plugin not registered (running on a non-iOS/macOS target?)';
        _isRetrying = false;
        _meshStatus = 'renderer unavailable';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _textureError = '${e.code}: ${e.message}';
        _isRetrying = false;
        _meshStatus = 'renderer unavailable';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
    }
  }

  @override
  void dispose() {
    _meshStatusHideTimer?.cancel();
    _splashMinTimer?.cancel();
    _splashMaxTimer?.cancel();
    _lifecycle?.dispose();
    final id = _textureId;
    if (id != null) {
      _channel
          .invokeMethod('disposeTexture', {'textureId': id})
          .catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _loadDefaultGlb(int textureId) async {
    const filename = 'DamagedHelmet.glb';
    String? found = await _materializeBundledGlb(filename);

    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/aether_cpp/build/test_assets/$filename',
      '$cwd/../aether_cpp/build/test_assets/$filename',
      '$cwd/../../aether_cpp/build/test_assets/$filename',
      '/Users/kaidongwang/Documents/Aether3D-cross/aether_cpp/build/test_assets/$filename',
    ];
    if (found == null) {
      for (final c in candidates) {
        try {
          if (await File(c).exists()) {
            found = c;
            break;
          }
        } catch (_) {}
      }
    }
    if (found == null) {
      if (!mounted) return;
      setState(() {
        _meshStatus =
            'mesh: $filename not found (asset bundle + cwd / ../ / ../../ / dev abspath)';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
      return;
    }
    try {
      if (!mounted) return;
      setState(() {
        _meshStatus = 'loading $filename...';
        _meshStatusBusy = true;
        _meshStatusError = false;
      });
      await _channel.invokeMethod('loadGlb', {
        'textureId': textureId,
        'path': found,
      });
      if (!mounted) return;
      const readyStatus = 'mesh ready';
      setState(() {
        _meshStatus = readyStatus;
        _meshStatusBusy = false;
        _meshStatusError = false;
      });
      _scheduleMeshStatusAutoHide(readyStatus);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _meshStatus = 'mesh: ${e.code} - ${e.message ?? "(no message)"}';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
    }
  }

  Future<String?> _materializeBundledGlb(String filename) async {
    final assetPath = 'assets/models/$filename';
    try {
      final bytes = await rootBundle.load(assetPath);
      final dir = Directory('${Directory.systemTemp.path}/aether3d_assets');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: false,
      );
      return file.path;
    } catch (e) {
      debugPrint('[PocketWorld] bundled GLB materialize miss: $e');
      return null;
    }
  }

  void _scheduleMeshStatusAutoHide(String statusToHide) {
    _meshStatusHideTimer?.cancel();
    _meshStatusHideTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted || _meshStatus != statusToHide) return;
      setState(() {
        _meshStatus = null;
        _meshStatusBusy = false;
        _meshStatusError = false;
      });
    });
  }

  void _pushMatrices() {
    final id = _textureId;
    if (id == null) return;
    final viewBytes = _orbit.viewMatrix();
    final modelBytes = _object.modelMatrix();
    _channel
        .invokeMethod('setMatrices', {
          'textureId': id,
          'view': viewBytes,
          'model': modelBytes,
        })
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    // DesignInspectorHost wrapper removed 2026-04-29 — the floating ✨
    // toggle, the dashed-border DesignBox overlays, and the bottom
    // legend were dev affordances that are no longer wanted in the
    // shipped UI. The DesignBox call sites stay (they pass through
    // their child when no DesignInspector ancestor exists), so we don't
    // have to surgically remove every one.
    //
    // _buildCapturePage / capture-page state plumbing removed 2026-04-29
    // — the old Dawn-backed CapturePage + CaptureModeSelectionPage are
    // gone, awaiting the Aether3D capture-pipeline port (ARKit + dome
    // + FrameAnalyzer + A100 remote pipeline). The "_textureId / _orbit
    // / _meshStatus" state on this State class is now dead code; left
    // in place for the moment because the texture acquisition path
    // (_requestTexture, _loadGlbAsset, _handleScaleUpdate) is what the
    // ported capture flow will reattach to.
    return Stack(
      children: [
        // 2026-08-16 — the two-tab shell is routed to again. It was
        // swapped for MeRootPage in cf68313 ("V1 IA") when the community
        // feed had no way to be fed: the publish chain had been deleted
        // in Plan G W2, so the tab could only ever show an empty list.
        // PublishService is back and points to the sparse cloud the
        // capture route actually produces, so 社区 has content and earns
        // its tab. MeRootPage stays in the tree — flipping this one line
        // back is how we ship a community-less build if we ever need to.
        const AetherAppShell(),
        Positioned.fill(
          child: AetherSplashOverlay(
            visible: _splashVisible,
            progressMessage: _splashMessage(context),
            exitStyle: SplashExitStyle.directLineDoor,
          ),
        ),
      ],
    );
  }
}
