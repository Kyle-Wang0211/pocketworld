// 「一次重建只信一个设备跟踪会话的位姿」契约(device_pose_session.dart)。
//
// 固定件用**真机数据**:cap_1789119308200005(pw_backups/pw102_20260906/
// backup151_20260911)—— 第一次拍 7 张后手机重启(ARKit 时钟 13388.5 → 321.8),
// 补拍 16 张;收尾整项目重喂把两个世界系的外参一起喂给了核(差绕重力 34.4°)。
// 账本原文:.dead-1789119652800 = 第一次拍摄实拍喂进的 6 张,
// .dead-1789119692590 = 补拍实拍喂进的 13 张,当前账本 = 重喂的全部 23 张。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/archived_photo_rebuild.dart';
import 'package:pocketworld_flutter/official_capture/device_pose_session.dart';
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';
import 'package:pocketworld_flutter/official_capture/photo_slot_naming.dart';
import 'package:pocketworld_flutter/official_capture/sfm_resume.dart'
    as sfm_resume;

/// (tap-N, sidecar t) 按拍摄序。
const List<(int, double)> kCap0005Shots = <(int, double)>[
  (1, 13376.985),
  (13, 13378.852),
  (21, 13379.919),
  (28, 13381.052),
  (34, 13381.919),
  (42, 13383.119),
  (74, 13388.519),
  (75, 321.815),
  (79, 324.449),
  (176, 340.517),
  (186, 341.783),
  (193, 342.917),
  (201, 344.084),
  (217, 346.517),
  (224, 347.75),
  (231, 348.584),
  (237, 349.451),
  (244, 350.401),
  (252, 351.667),
  (260, 352.667),
  (267, 353.834),
  (274, 354.834),
  (281, 355.801),
];
const List<int> kCap0005Dead1 = <int>[1, 13, 21, 28, 34, 42];
const List<int> kCap0005Dead2 = <int>[
  75, 79, 176, 186, 193, 201, 217, 224, 231, 237, 252, 260, 274, //
];

String photo(int n) => 'official_tap-$n.jpg';

List<DevicePoseSessionEvidence> legacyEvidence(List<(int, double)> shots) => [
  for (final (n, t) in shots)
    DevicePoseSessionEvidence(photoName: photo(n), captureTimestamp: t),
];

void main() {
  group('planDevicePoseTrust — 有逐张会话记录(新数据)', () {
    test('🔴 两个会话:非参考会话全部不可信,参考 = 照片最多的那个', () {
      final shots = <DevicePoseSessionEvidence>[
        for (final (n, t) in kCap0005Shots)
          DevicePoseSessionEvidence(
            photoName: photo(n),
            captureTimestamp: t,
            hasRecord: true,
            recordedSessionId: n <= 74 ? 'arkit-A#0' : 'arkit-B#0',
          ),
      ];
      final plan = planDevicePoseTrust(shotsInOrder: shots);
      expect(plan.sessionCount, 2);
      expect(plan.referenceSession, 'rec:arkit-B#0');
      for (final (n, _) in kCap0005Shots) {
        expect(
          plan.isTrusted(photo(n)),
          n >= 75,
          reason: 'tap-$n 属于 ${n <= 74 ? "第一次拍摄" : "补拍"}',
        );
      }
      expect(plan.trustedCount, 16);
    });

    test('阴性对照:单会话 ⇒ 全部可信(与改前逐位一致)', () {
      final shots = <DevicePoseSessionEvidence>[
        for (final (n, t) in kCap0005Shots.skip(7))
          DevicePoseSessionEvidence(
            photoName: photo(n),
            captureTimestamp: t,
            hasRecord: true,
            recordedSessionId: 'arkit-B#0',
          ),
      ];
      final plan = planDevicePoseTrust(shotsInOrder: shots);
      expect(plan.sessionCount, 1);
      expect(shots.every((s) => plan.isTrusted(s.photoName)), isTrue);
    });

    test('并列取最早开拍的;不足 3 张的会话不能当参考', () {
      DevicePoseSessionEvidence e(int n, String id) =>
          DevicePoseSessionEvidence(
            photoName: photo(n),
            captureTimestamp: n.toDouble(),
            hasRecord: true,
            recordedSessionId: id,
          );
      final tie = planDevicePoseTrust(
        shotsInOrder: [
          e(1, 'a'), e(2, 'a'), e(3, 'a'), //
          e(4, 'b'), e(5, 'b'), e(6, 'b'),
        ],
      );
      expect(tie.referenceSession, 'rec:a');
      final tiny = planDevicePoseTrust(
        shotsInOrder: [e(1, 'a'), e(2, 'a'), e(3, 'b'), e(4, 'b')],
      );
      expect(tiny.referenceSession, isNull);
      expect(tiny.trustedCount, 0);
    });

    test('拍时归属不明(记录为 null)的照片永不可信,也不凑成一组', () {
      final shots = <DevicePoseSessionEvidence>[
        for (var n = 1; n <= 5; n++)
          DevicePoseSessionEvidence(
            photoName: photo(n),
            captureTimestamp: n.toDouble(),
            hasRecord: true,
            recordedSessionId: n == 3 ? null : 'a',
          ),
      ];
      final plan = planDevicePoseTrust(shotsInOrder: shots);
      expect(plan.isTrusted(photo(3)), isFalse);
      expect(plan.trustedCount, 4);
    });
  });

  group('planDevicePoseTrust — 旧数据(没有逐张记录,只信证据)', () {
    test('🔴 cap_1789119308200005 原文:第一次拍摄的 7 张全部不可信', () {
      final plan = planDevicePoseTrust(
        shotsInOrder: legacyEvidence(kCap0005Shots),
        ledgerPhotoSets: [
          {for (final (n, _) in kCap0005Shots) photo(n)}, // 重喂账本
          {for (final n in kCap0005Dead1) photo(n)},
          {for (final n in kCap0005Dead2) photo(n)},
        ],
        legacyMultiSessionTrace: true,
      );
      for (final (n, _) in kCap0005Shots.take(7)) {
        expect(plan.isTrusted(photo(n)), isFalse, reason: 'tap-$n 是旧世界');
      }
      // 补拍实拍账本证实 tap-75..274(含夹在中间没来得及喂的 244/267);
      // tap-281 在账本之后,归属未证实 ⇒ 不可信(只会更保守)。
      final trusted = [
        for (final (n, _) in kCap0005Shots)
          if (plan.isTrusted(photo(n))) n,
      ];
      expect(trusted.first, 75);
      expect(trusted.last, 274);
      expect(trusted.length, 15);
      expect(plan.isTrusted(photo(281)), isFalse);
    });

    test('只有时钟倒退、没有任何账本 ⇒ 没有证据,谁都不可信', () {
      final plan = planDevicePoseTrust(
        shotsInOrder: legacyEvidence(kCap0005Shots),
      );
      expect(plan.referenceSession, isNull);
    });

    test('阴性对照:正常单次拍摄(无痕迹、时钟单调)⇒ 全部可信', () {
      final shots = legacyEvidence(kCap0005Shots.skip(7).toList());
      final plan = planDevicePoseTrust(
        shotsInOrder: shots,
        ledgerPhotoSets: [
          {for (final s in shots) s.photoName},
        ],
      );
      expect(shots.every((s) => plan.isTrusted(s.photoName)), isTrue);
    });

    test('同一次开机里的补拍(时钟不倒退)不会被当成同一个会话', () {
      // cap_1788790152081296 的形状:第 3 段与第 2 段同一次开机、隔 7808 s。
      final shots = <(int, double)>[
        for (var i = 0; i < 10; i++) (1 + i, 113183.0 + i),
        for (var i = 0; i < 20; i++) (165 + i, 39047.0 + i),
        for (var i = 0; i < 3; i++) (431 + i, 46890.0 + i),
      ];
      final plan = planDevicePoseTrust(
        shotsInOrder: legacyEvidence(shots),
        ledgerPhotoSets: [
          {for (var i = 0; i < 9; i++) photo(1 + i)},
        ],
        legacyMultiSessionTrace: true,
      );
      expect(plan.trustedCount, 9);
      expect(plan.isTrusted(photo(431)), isFalse);
      expect(plan.isTrusted(photo(165)), isFalse);
    });

    test('跨越时钟倒退的账本不作证据(那是重喂账本,不是一次实拍)', () {
      final plan = planDevicePoseTrust(
        shotsInOrder: legacyEvidence(kCap0005Shots),
        ledgerPhotoSets: [
          {for (final (n, _) in kCap0005Shots) photo(n)},
        ],
        legacyMultiSessionTrace: true,
      );
      expect(plan.referenceSession, isNull);
    });
  });

  group('DevicePoseSessionTracker — 拍摄期边界', () {
    DevicePoseSessionTracker fresh() =>
        DevicePoseSessionTracker(idPrefix: 't')
          ..beginRun(reason: 'capture_run');

    test('切后台后 relocalizing → normal = 接回原世界系(同一会话)', () {
      final tr = fresh();
      tr.observe(DeviceTrackingPhase.normal, 10);
      tr.suspend();
      expect(tr.sessionAt(12), isNull, reason: '判定出来之前归属不明');
      tr.observe(DeviceTrackingPhase.relocalizing, 30);
      tr.observe(DeviceTrackingPhase.normal, 33);
      expect(tr.sessionCount, 1);
      expect(tr.isTrustedAt(40), isTrue);
    });

    test('🔴 切后台后直接 initializing(ARKit 放弃重定位、重启)= 新会话', () {
      final tr = fresh();
      tr.observe(DeviceTrackingPhase.normal, 10);
      tr.suspend();
      tr.observe(DeviceTrackingPhase.relocalizing, 30);
      tr.observe(DeviceTrackingPhase.initializing, 34);
      tr.observe(DeviceTrackingPhase.normal, 36);
      expect(tr.sessionCount, 2);
      expect(tr.isTrustedAt(9), isTrue);
      expect(tr.isTrustedAt(40), isFalse);
      expect(tr.sessionAt(40), isNot(tr.referenceSessionId));
    });

    test('没观测到 relocalizing 就 normal ⇒ 连续性没证明 ⇒ 新会话', () {
      final tr = fresh();
      tr.observe(DeviceTrackingPhase.normal, 10);
      tr.suspend();
      tr.observe(DeviceTrackingPhase.normal, 30);
      expect(tr.sessionCount, 2);
      expect(tr.isTrustedAt(31), isFalse);
    });

    test('XRSLAM(不支持重定位):恢复后一律新会话', () {
      final tr = fresh();
      tr.observe(DeviceTrackingPhase.normal, 10);
      tr.suspend(platformCanRelocalize: false);
      tr.observe(DeviceTrackingPhase.relocalizing, 30);
      tr.observe(DeviceTrackingPhase.normal, 31);
      expect(tr.sessionCount, 2);
    });

    test('不切后台,normal 之后又 initializing(跟踪被重启)= 新会话', () {
      final tr = fresh();
      tr.observe(DeviceTrackingPhase.initializing, 1);
      tr.observe(DeviceTrackingPhase.normal, 2);
      tr.observe(DeviceTrackingPhase.limitedOther, 3); // 快速运动不算边界
      tr.observe(DeviceTrackingPhase.normal, 4);
      expect(tr.sessionCount, 1);
      tr.observe(DeviceTrackingPhase.initializing, 5);
      expect(tr.sessionCount, 2);
      expect(tr.isTrustedAt(4.5), isTrue);
      expect(tr.isTrustedAt(5), isFalse);
    });

    test('阴性对照:一路 normal 的单次拍摄 ⇒ 永远一个会话、全部可信', () {
      final tr = fresh();
      for (var t = 0.0; t < 60; t += 0.5) {
        tr.observe(DeviceTrackingPhase.normal, t);
      }
      expect(tr.sessionCount, 1);
      expect(tr.isTrustedAt(59), isTrue);
    });

    test('ARKit 名字映射', () {
      expect(
        deviceTrackingPhaseFromArkitName('limited_relocalizing'),
        DeviceTrackingPhase.relocalizing,
      );
      expect(
        deviceTrackingPhaseFromArkitName('limited_initializing'),
        DeviceTrackingPhase.initializing,
      );
      expect(
        deviceTrackingPhaseFromArkitName('limited_excessive_motion'),
        DeviceTrackingPhase.limitedOther,
      );
      expect(
        deviceTrackingPhaseFromArkitName(null),
        DeviceTrackingPhase.limitedOther,
      );
    });
  });

  group('契约字段', () {
    OfficialHighResReconstructionInput input() =>
        OfficialHighResReconstructionInput.validate(
          jpegPath: '/x/official_tap-1.jpg',
          imageWidth: 4032,
          imageHeight: 3024,
          triggerTimestamp: 1,
          captureTimestamp: 1,
          cameraTransform: List<double>.generate(
            16,
            (i) => i % 5 == 0 ? 1.0 : 0.0,
          ),
          intrinsics: const <double>[2800, 2800, 2016, 1512],
          trackingStateName: 'normal',
        ).input!;

    test('追踪 normal 的帧默认可信、无会话(A 的判据不变)', () {
      final i = input();
      expect(i.devicePoseTrusted, isTrue);
      expect(i.deviceSessionId, isNull);
    });

    test('非参考会话:原因记成 device_session_not_reference;A 已判的原因保留', () {
      final s = input().withDevicePoseSession(
        deviceSessionId: 'x',
        devicePoseTrusted: false,
      );
      expect(s.devicePoseTrust.reason, 'device_session_not_reference');
      expect(s.devicePoseTrust.trackerState, 'normal');
      final limited = OfficialHighResReconstructionInput.validate(
        jpegPath: '/x/official_tap-2.jpg',
        imageWidth: 4032,
        imageHeight: 3024,
        triggerTimestamp: 1,
        captureTimestamp: 1,
        cameraTransform: input().cameraTransform,
        intrinsics: const <double>[2800, 2800, 2016, 1512],
        trackingStateName: 'limited_initializing',
      ).input!;
      final both = limited.withDevicePoseSession(
        deviceSessionId: 'x',
        devicePoseTrusted: true,
      );
      expect(both.devicePoseTrusted, isFalse, reason: '会话可信也不能放宽 A 的判决');
      expect(both.devicePoseTrust.reason, 'tracker_limited_initializing');
    });

    test('信任位只能收紧,不能被改回 true', () {
      final untrusted = input().withDevicePoseSession(
        deviceSessionId: 'a',
        devicePoseTrusted: false,
      );
      expect(untrusted.devicePoseTrusted, isFalse);
      final again = untrusted.withDevicePoseSession(
        deviceSessionId: 'a',
        devicePoseTrusted: true,
      );
      expect(again.devicePoseTrusted, isFalse);
      expect(again.cameraTransform, input().cameraTransform);
    });

    test('逐张记录读写往返;坏行跳过', () {
      final text = <String>[
        encodeDeviceSessionLedgerLine(
          photoName: 'official_tap-1.jpg',
          deviceSessionId: 'arkit-1#0',
          captureTimestamp: 1.5,
          source: 'arkit',
        ),
        'garbage\n',
        encodeDeviceSessionLedgerLine(
          photoName: 'official_tap-2.jpg',
          deviceSessionId: null,
          captureTimestamp: 2.5,
          source: 'arkit',
        ),
      ].join();
      final m = parseDeviceSessionLedger(text);
      expect(m['official_tap-1.jpg'], 'arkit-1#0');
      expect(m.containsKey('official_tap-2.jpg'), isTrue);
      expect(m['official_tap-2.jpg'], isNull);
    });
  });

  group('「开始训练」路由:改前写的混会话 db 不许照 db 续跑', () {
    String ledgerLine(int fid, int n, double t, {bool? trusted}) {
      final m = <String, Object?>{
        'frameId': fid,
        'jpegPath': photo(n),
        'captureTimestamp': t,
      };
      if (trusted != null) m['devicePoseTrusted'] = trusted;
      return jsonEncode(m);
    }

    test('🔴 改前的重喂账本 + .dead-* ⇒ 覆盖度判"不齐",走全量重喂', () {
      final jsonl = [
        for (var i = 0; i < kCap0005Shots.length; i++)
          ledgerLine(i, kCap0005Shots[i].$1, kCap0005Shots[i].$2),
      ].join('\n');
      final mixed = legacyLedgerMayMixDeviceSessions(
        jsonl,
        deadLedgersPresent: true,
        frameSeqOf: frameSeqInName,
      );
      expect(mixed, isTrue);
      final c = projectCoverageFrom(
        jpegNamesOnDisk: [for (final (n, _) in kCap0005Shots) photo(n)],
        fedFramesJsonl: jsonl,
        ledgerMayMixDeviceSessions: mixed,
      );
      expect(c.neverFed, isEmpty);
      expect(c.duplicateFrameIds, 0);
      expect(c.covered, isFalse, reason: '前两条腿都放行,只有第三条能拦');
      // 没有 .dead-* 时,账本自己的时钟倒退也能拦。
      expect(
        legacyLedgerMayMixDeviceSessions(
          jsonl,
          deadLedgersPresent: false,
          frameSeqOf: frameSeqInName,
        ),
        isTrue,
      );
    });

    test('阴性对照:正常单次拍摄的旧账本 / 带信任位的新账本 ⇒ 不拦', () {
      final single = [
        for (var i = 0; i < 16; i++)
          ledgerLine(i, kCap0005Shots[7 + i].$1, kCap0005Shots[7 + i].$2),
      ].join('\n');
      expect(
        legacyLedgerMayMixDeviceSessions(
          single,
          deadLedgersPresent: false,
          frameSeqOf: frameSeqInName,
        ),
        isFalse,
      );
      final fresh = [
        for (var i = 0; i < kCap0005Shots.length; i++)
          ledgerLine(
            i,
            kCap0005Shots[i].$1,
            kCap0005Shots[i].$2,
            trusted: i >= 7,
          ),
      ].join('\n');
      expect(
        legacyLedgerMayMixDeviceSessions(
          fresh,
          deadLedgersPresent: true,
          frameSeqOf: frameSeqInName,
        ),
        isFalse,
      );
    });
  });

  group('新账本:实时参考(本场第一个会话)不是最大会话 ⇒ 送去重排', () {
    String line(int fid, String sid, bool trusted) => jsonEncode({
      'frameId': fid,
      'jpegPath': photo(fid),
      'deviceSessionId': sid,
      'devicePoseTrusted': trusted,
    });

    test('🔴 cap_1787733401226757 形状:第一个会话 1 张、第二个 19 张', () {
      final jsonl = [
        line(0, 'arkit-1#0', true),
        for (var i = 1; i < 20; i++) line(i, 'arkit-1#1', false),
      ].join('\n');
      expect(ledgerNeedsDeviceSessionReplan(jsonl), isTrue);
    });

    test('阴性对照:重喂后的账本(参考 = 最大)/ 单会话 ⇒ 不重排', () {
      final replanned = [
        line(0, 'rec:arkit-1#0', false),
        for (var i = 1; i < 20; i++) line(i, 'rec:arkit-1#1', i > 3),
      ].join('\n');
      expect(ledgerNeedsDeviceSessionReplan(replanned), isFalse);
      final single = [
        for (var i = 0; i < 20; i++) line(i, 'arkit-1#0', true),
      ].join('\n');
      expect(ledgerNeedsDeviceSessionReplan(single), isFalse);
    });
  });

  group('planArchivedRefeed 端到端(临时目录,真实文件布局)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pw_devsess_'));
    tearDown(() => dir.deleteSync(recursive: true));

    void writeShot(int n, double t) {
      final photos = Directory('${dir.path}/photos_highres')
        ..createSync(recursive: true);
      File('${photos.path}/${photo(n)}').writeAsBytesSync(const <int>[0xFF]);
      File('${photos.path}/official_tap-$n.json').writeAsStringSync(
        jsonEncode({
          'intrinsics_fxfycxcy': [2831.1, 2831.1, 2023.3, 1510.8],
          'extrinsic': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.01 * n, 0, 0, 1],
          'image_w': 4032,
          'image_h': 3024,
          't': t,
          'save_target_t': t,
          // 真机 sidecar 原文:tap-79 是 limited_initializing,其余 normal。
          'tracking_state': n == 79 ? 'limited_initializing' : 'normal',
          'trackingStateName': n == 79 ? 'limited_initializing' : 'normal',
        }),
      );
    }

    void writeLedger(String name, List<int> seqs) {
      final byN = {for (final (n, t) in kCap0005Shots) n: t};
      File('${dir.path}/$name').writeAsStringSync(
        [
          for (var i = 0; i < seqs.length; i++)
            jsonEncode({
              'frameId': i,
              'jpegPath': '/var/x/${photo(seqs[i])}',
              'captureTimestamp': byN[seqs[i]],
            }),
        ].join('\n'),
      );
    }

    test('🔴 cap_1789119308200005 的文件布局 ⇒ 喂出去的旧世界帧全部 untrusted', () async {
      for (final (n, t) in kCap0005Shots) {
        writeShot(n, t);
      }
      writeLedger('official_sfm_fed_frames.jsonl', [
        for (final (n, _) in kCap0005Shots) n,
      ]);
      writeLedger(
        'official_sfm_fed_frames.jsonl.dead-1789119652800',
        kCap0005Dead1,
      );
      writeLedger(
        'official_sfm_fed_frames.jsonl.dead-1789119692590',
        kCap0005Dead2,
      );
      final plan = await sfm_resume.planArchivedRefeed(dir.path);
      expect(plan.ordered.length, 23);
      final fed = {
        for (final p in plan.ordered)
          frameSeqInName(p.jpegPath.split('/').last)!: p.input!,
      };
      for (final n in [1, 13, 21, 28, 34, 42, 74]) {
        expect(fed[n]!.devicePoseTrusted, isFalse, reason: 'tap-$n');
      }
      expect(fed[75]!.devicePoseTrusted, isTrue);
      expect(fed[274]!.devicePoseTrusted, isTrue);
      // 会话计划信 15 张;其中 tap-79 自己那一帧 limited_initializing,A 的判据
      // 再收紧一张 ⇒ 实际可信 14。
      expect(plan.deviceTrust!.trustedCount, 15);
      expect(fed[79]!.devicePoseTrusted, isFalse);
      expect(plan.ordered.where((p) => p.input!.devicePoseTrusted).length, 14);
      // 顺序与外参原样(只加了信任位,别的字段一个不动)。
      expect(plan.ordered.first.jpegPath.endsWith(photo(1)), isTrue);
      expect(fed[75]!.cameraTransform[12], closeTo(0.75, 1e-12));
    });

    test('改前的补拍把两次实拍接着写进同一份账本(frameId 回落)⇒ 按回落切段作证据', () async {
      // cap_1789105782936554(未命名(8))的形状:frameId 0..13 后又从 0 数了 6 帧。
      final s1 = [for (var i = 0; i < 20; i++) (2 + 10 * i, 94000.0 + i)];
      final s2 = [for (var i = 0; i < 6; i++) (219 + 10 * i, 270.0 + i)];
      final byN = {
        for (final (n, t) in [...s1, ...s2]) n: t,
      };
      for (final (n, t) in [...s1, ...s2]) {
        writeShot(n, t);
      }
      final fed = [...s1.take(14), ...s2];
      File('${dir.path}/official_sfm_fed_frames.jsonl').writeAsStringSync(
        [
          for (var i = 0; i < fed.length; i++)
            jsonEncode({
              'frameId': i < 14 ? i : i - 14,
              'jpegPath': photo(fed[i].$1),
              'captureTimestamp': byN[fed[i].$1],
            }),
        ].join('\n'),
      );
      final plan = await sfm_resume.planArchivedRefeed(dir.path);
      // 第一次实拍账本证实 tap-2..132(14 张);之后 6 张没进账本 ⇒ 未证实。
      expect(plan.deviceTrust!.trustedCount, 14);
      for (final (n, _) in s2) {
        expect(
          plan.ordered
              .firstWhere((p) => p.jpegPath.endsWith(photo(n)))
              .input!
              .devicePoseTrusted,
          isFalse,
        );
      }
    });

    test('有逐张会话记录时按记录分组(补拍会话 16 张全部可信)', () async {
      for (final (n, t) in kCap0005Shots) {
        writeShot(n, t);
      }
      File('${dir.path}/$kDeviceSessionLedgerFileName').writeAsStringSync(
        [
          for (final (n, t) in kCap0005Shots)
            encodeDeviceSessionLedgerLine(
              photoName: photo(n),
              deviceSessionId: n <= 74 ? 'arkit-A#0' : 'arkit-B#0',
              captureTimestamp: t,
              source: 'arkit',
            ),
        ].join(),
      );
      final plan = await sfm_resume.planArchivedRefeed(dir.path);
      final trusted = plan.ordered.where((p) => p.input!.devicePoseTrusted);
      expect(trusted.length, 15, reason: '16 张补拍会话 − tap-79(A 判不可信)');
      expect(
        trusted.every((p) => p.input!.deviceSessionId == 'rec:arkit-B#0'),
        isTrue,
      );
    });

    test('阴性对照:单次拍摄(一份实拍账本覆盖全部)⇒ 全部可信', () async {
      final single = kCap0005Shots.skip(7).toList();
      for (final (n, t) in single) {
        writeShot(n, t);
      }
      writeLedger('official_sfm_fed_frames.jsonl', [
        for (final (n, _) in single) n,
      ]);
      final plan = await sfm_resume.planArchivedRefeed(dir.path);
      expect(plan.ordered.length, 16);
      expect(
        plan.ordered
            .where((p) => !p.input!.devicePoseTrusted)
            .map((p) => p.jpegPath.split('/').last),
        [photo(79)],
        reason: '单会话:会话层一张不动,只剩 A 判的 tap-79',
      );
    });
  });

  group('接线(源码契约)', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final recon = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();

    test('实时喂帧经过会话跟踪器盖章,不再直接 listen(recon.offerFrame)', () {
      expect(page, isNot(contains('sfmFrameStream.listen(recon.offerFrame)')));
      expect(
        page,
        contains('_offerLiveFrame(recon, tracker, captureDir, frame)'),
      );
      expect(page, contains('_deviceSessions?.suspend();'));
      expect(page, contains('deviceTrackingPhaseFromArkitName(tsName)'));
      expect(page, contains('multiDeviceSessionTake'));
    });

    test('会话 id 随喂帧记录落账;尺度锚只读可信帧', () {
      expect(recon, contains("'deviceSessionId': m.deviceSessionId"));
      expect(recon, contains('deviceSessionId: feed.deviceSessionId'));
      expect(
        recon,
        isNot(contains('_fedMeta[frameId]?.arkitCameraCenterWorld')),
      );
      expect(recon, isNot(contains('_fedMeta[frameId]?.arkitQuatWxyz')));
    });

    test('续跑读回信任位与会话,换 jpeg 路径也不丢', () {
      final resume = File(
        'lib/official_capture/sfm_resume.dart',
      ).readAsStringSync();
      expect(
        resume,
        contains("devicePoseTrusted: m['devicePoseTrusted'] as bool? ?? true"),
      );
      expect(resume, contains('devicePoseTrusted: meta.devicePoseTrusted'));
      expect(resume, contains('deviceSessionId: meta.deviceSessionId'));
    });
  });
}
