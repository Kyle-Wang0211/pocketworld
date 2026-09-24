// camera_time_offset_test.dart —— 每机常量 c 的查表判据。
//
// 四组:
//   (A) 查表命中:`iPhone15,2` → 3 ms,provenance = measured,note 带录制 id;
//   (B) 未测机型 / 机型未知 → **0**,provenance = PLACEHOLDER。
//       🔴 这一组是本文件的重点:不许「顺手」把 14 Pro 的 3 ms 搬给别的机型;
//   (C) `--dart-define=PW_CAM_TD_MS` 覆盖优先,且打错字**不静默当 0**;
//   (D) 机型标识符走仓里已有的那条通道(`IosTimebaseChannel.deviceMachine`),
//       通道不存在时降级成「机型未知」而不是抛。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/capture/camera_time_offset.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_extrinsics.dart';
import 'package:pocketworld_flutter/vio/timebase/ios_timebase_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(PwDeviceMachine.debugReset);

  group('(A) 查表命中', () {
    test('iPhone15,2 → 3 ms / measured / note 带录制 id', () {
      final CameraTimeOffset c = resolveCameraTimeOffset(
        machine: 'iPhone15,2',
        overrideMillisRaw: '',
      );
      expect(c.seconds, closeTo(0.003, 1e-12));
      expect(c.milliseconds, closeTo(3.0, 1e-9));
      expect(c.provenance, FieldProvenance.measured);
      expect(c.isMeasuredForThisDevice, isTrue);
      expect(c.machine, 'iPhone15,2');
      expect(c.note, contains('run-4ad6e500'));
    });

    test('可核的一行 = c=3.00ms provenance=measured(iPhone15,2)', () {
      expect(
        resolveCameraTimeOffset(machine: 'iPhone15,2', overrideMillisRaw: '')
            .describe,
        'c=3.00ms provenance=measured(iPhone15,2)',
      );
    });

    test('表与 note 表键一一对应(加了值却不写来源 = 下次没人说得清它哪来的)', () {
      expect(
        kIosCameraTimeOffsetNotes.keys.toSet(),
        kIosCameraTimeOffsetSeconds.keys.toSet(),
      );
    });

    test('🔴 键用 hw.machine —— 与仓里已有的外参表同一套词汇', () {
      // 拼错一个字符就静默回退到 0,而且不报错。拿已有的那张表当对照。
      for (final String machine in kIosCameraTimeOffsetSeconds.keys) {
        expect(
          kIosCameraImuPbc.containsKey(machine),
          isTrue,
          reason: '$machine 不在 kIosCameraImuPbc 里 —— '
              '要么拼错了,要么用了营销名',
        );
      }
    });
  });

  group('(B) 未测机型就是 0', () {
    test('🔴 没测过的机型 → 0 / PLACEHOLDER,**不拿 3 ms 顶**', () {
      final CameraTimeOffset c = resolveCameraTimeOffset(
        machine: 'iPhone99,9',
        overrideMillisRaw: '',
      );
      expect(c.seconds, 0.0);
      expect(c.provenance, FieldProvenance.placeholder);
      expect(c.isMeasuredForThisDevice, isFalse);
      expect(c.machine, 'iPhone99,9');
      expect(c.note, contains('没测过'));
    });

    test('机型未知(查表还没回来 / 非 iOS)→ 0 / PLACEHOLDER', () {
      final CameraTimeOffset c =
          resolveCameraTimeOffset(machine: null, overrideMillisRaw: '');
      expect(c.seconds, 0.0);
      expect(c.provenance, FieldProvenance.placeholder);
      expect(c.machine, isNull);
      expect(c.describe, contains('机型未知'));
    });

    test('🔴 表里只有实测过的机型 —— 现在就一行', () {
      expect(kIosCameraTimeOffsetSeconds, hasLength(1));
      expect(kIosCameraTimeOffsetSeconds.keys.single, 'iPhone15,2');
    });
  });

  group('(C) dart-define 覆盖', () {
    test('覆盖优先于查表(同一台 iPhone15,2 也被盖掉)', () {
      final CameraTimeOffset c = resolveCameraTimeOffset(
        machine: 'iPhone15,2',
        overrideMillisRaw: '8',
      );
      expect(c.seconds, closeTo(0.008, 1e-12));
      expect(c.provenance, FieldProvenance.devOverride);
      expect(c.isMeasuredForThisDevice, isFalse,
          reason: '命令行传进来的数不是「这台机实测」');
      expect(c.note, contains('PW_CAM_TD_MS'));
    });

    test('未知机型上覆盖同样生效(扫参数用)', () {
      final CameraTimeOffset c = resolveCameraTimeOffset(
        machine: 'iPhone99,9',
        overrideMillisRaw: '-2.5',
      );
      expect(c.seconds, closeTo(-0.0025, 1e-12));
      expect(c.provenance, FieldProvenance.devOverride);
    });

    test('🔴 显式传 0 ≠ 没传:前者 dev-override,后者才查表', () {
      expect(
        resolveCameraTimeOffset(machine: 'iPhone15,2', overrideMillisRaw: '0')
            .provenance,
        FieldProvenance.devOverride,
      );
      expect(
        resolveCameraTimeOffset(machine: 'iPhone15,2', overrideMillisRaw: '')
            .provenance,
        FieldProvenance.measured,
      );
      expect(
        resolveCameraTimeOffset(machine: 'iPhone15,2', overrideMillisRaw: '   ')
            .provenance,
        FieldProvenance.measured,
        reason: '全空白与没传同义',
      );
    });

    test('🔴 打错字不静默当 0 —— 落回 PLACEHOLDER 并在 note 里点名', () {
      for (final String bad in <String>['abc', 'NaN', 'Infinity', '3ms']) {
        final CameraTimeOffset c =
            resolveCameraTimeOffset(machine: 'iPhone15,2', overrideMillisRaw: bad);
        expect(c.seconds, 0.0, reason: bad);
        expect(c.provenance, FieldProvenance.placeholder, reason: bad);
        expect(c.note, contains(bad), reason: bad);
      }
    });

    test('键名与台架页同一个,不另起一个', () {
      expect(kCameraTimeOffsetOverrideKey, 'PW_CAM_TD_MS');
    });

    test('dev-override 的标签与其它四态互不相同', () {
      expect(FieldProvenance.devOverride.label, 'dev-override');
      expect(
        FieldProvenance.values.map((FieldProvenance p) => p.label).toSet(),
        hasLength(FieldProvenance.values.length),
      );
    });
  });

  group('(D) 机型标识符的取法', () {
    const MethodChannel fake = MethodChannel('pw_device_machine_fake');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fake, null);
    });

    test('走已有的 deviceMachine 方法,缓存之后同步可读', () async {
      final List<String> methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fake, (MethodCall call) async {
        methods.add(call.method);
        return 'iPhone15,2';
      });

      expect(PwDeviceMachine.cached, isNull);
      expect(PwDeviceMachine.primed, isFalse);

      final String? m =
          await PwDeviceMachine.prime(channel: IosTimebaseChannel(fake));
      expect(m, 'iPhone15,2');
      expect(methods, <String>['deviceMachine']);
      expect(PwDeviceMachine.primed, isTrue);
      expect(PwDeviceMachine.cached, 'iPhone15,2');

      // 只读一次:第二次 prime 不再打通道。
      await PwDeviceMachine.prime(channel: IosTimebaseChannel(fake));
      expect(methods, <String>['deviceMachine']);

      expect(
        resolveCameraTimeOffset(
          machine: PwDeviceMachine.cached,
          overrideMillisRaw: '',
        ).seconds,
        closeTo(0.003, 1e-12),
      );
    });

    test('🔴 通道不存在(模拟器/单测/安卓)⇒ 降级成「机型未知」,不抛', () async {
      // 不装 mock handler ⇒ MissingPluginException。
      final String? m =
          await PwDeviceMachine.prime(channel: IosTimebaseChannel(fake));
      expect(m, isNull);
      expect(PwDeviceMachine.primed, isTrue);
      expect(
        resolveCameraTimeOffset(
          machine: PwDeviceMachine.cached,
          overrideMillisRaw: '',
        ).provenance,
        FieldProvenance.placeholder,
      );
    });

    test('debugOverride 覆盖缓存(台架/单测用)', () async {
      PwDeviceMachine.debugOverride = 'iPhone15,2';
      expect(PwDeviceMachine.cached, 'iPhone15,2');
      expect(await PwDeviceMachine.prime(), 'iPhone15,2');
    });
  });
}
