// vio_pose_source_runtime_flag_test.dart —— 第二来源(运行期启动参数)的判据。
//
// 🔴 最重要的一条是**默认仍然关着**:加第二来源绝不能让默认值变松。
// 单测环境里 `pw_vio_pose_source` 这个符号根本不存在 ⇒ `raw` 返回 `null`
// ⇒ 当作没设 ⇒ arkit。这正是模拟器/安卓/没链进去时的真实行为。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/vio_pose_source_runtime_flag.dart';
import 'package:pocketworld_flutter/vio/pose/vio_pose_source_switch.dart';

void main() {
  tearDown(() {
    PwVioPoseSourceRuntimeFlag.debugReset();
    PwVioPoseSourceSwitch.debugOverride = null;
  });

  group('默认仍然是关的', () {
    test('符号不存在(单测/模拟器/安卓)⇒ raw == null ⇒ arkit', () {
      PwVioPoseSourceRuntimeFlag.debugReset();
      expect(PwVioPoseSourceRuntimeFlag.raw, isNull);
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
      expect(PwVioPoseSourceSwitch.isSelfVio, isFalse);
      expect(PwVioPoseSourceSwitch.currentProvenance, 'default_arkit');
    });

    test('符号在但没传参数(空串)⇒ 仍然 arkit', () {
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = '';
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
      expect(PwVioPoseSourceSwitch.currentProvenance, 'default_arkit');
    });

    test('🔴 打错字不会悄悄切过去,回落 arkit 且不抛', () {
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = 'xrsl';
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = 'XRSLAMM';
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = '随便什么';
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
    });
  });

  group('取或', () {
    test('启动参数说 xrslam ⇒ 打开,provenance = launch_argument', () {
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = 'xrslam';
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.xrslam);
      expect(PwVioPoseSourceSwitch.isSelfVio, isTrue);
      expect(PwVioPoseSourceSwitch.currentProvenance, 'launch_argument');
    });

    test('大小写与空白不敏感(与第一来源同一套解析)', () {
      for (final String raw in <String>[
        '  xrslam ',
        'XRSLAM',
        'SelfVio',
        ' selfvio',
      ]) {
        PwVioPoseSourceRuntimeFlag.debugOverrideRaw = raw;
        expect(
          PwVioPoseSourceSwitch.current,
          PwVioPoseSource.xrslam,
          reason: '"$raw" 没被认出来',
        );
      }
    });

    test('启动参数显式说 arkit ⇒ 仍然 arkit(不是「设了就开」)', () {
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = 'arkit';
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = 'platform';
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
    });

    test('debugOverride 优先级最高(测试臂不受第二来源影响)', () {
      PwVioPoseSourceRuntimeFlag.debugOverrideRaw = 'xrslam';
      PwVioPoseSourceSwitch.debugOverride = PwVioPoseSource.arkit;
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
      expect(PwVioPoseSourceSwitch.currentProvenance, 'debug_override');
    });
  });

  group('缓存', () {
    test('只读一次 —— 启动参数在进程生存期内不会变', () {
      PwVioPoseSourceRuntimeFlag.debugReset();
      expect(PwVioPoseSourceRuntimeFlag.attempted, isFalse);
      PwVioPoseSourceRuntimeFlag.raw;
      expect(PwVioPoseSourceRuntimeFlag.attempted, isTrue);
      // 第二次不再去碰符号(值仍是同一个)。
      expect(PwVioPoseSourceRuntimeFlag.raw, isNull);
    });
  });
}
