// 断点续跑 × 草稿卡片:胶囊与点云封面的即时性。
//
// [2026-08-08 用户实机指认] "拍摄结束后一直留在加载页面等待稀疏点云。当稀疏点云
// 成功生成后,我点击返回,回到草稿页面,但是最新的未命名(6)仍然显示照片封面和
// '未完成'状态。"
//
// 两个根因、两组守门:
//   ① 胶囊:badgeOf 只认拍摄页那条腿的 activeReconstructionCaptureDir,等待页的
//     断点续跑它不知道 ⇒ 续跑期间被算成"未完成",且 anyGenerating=false ⇒ 2 秒
//     轮询根本没开 ⇒ PLY 落盘后没人重算。修:draftBadgeWithResume 升格。
//   ② 封面:点云封面原先只在 live 路径的 persist 现场生成,续跑路径没挂 ⇒ 返回
//     草稿页还是照片。修:等待页 resume future 成功那一刻 ensureSparseThumb,
//     且刻意放在 mounted 检查之前(提前返回、页已销毁也要画)。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/sfm_resume.dart'
    as official;
import 'package:pocketworld_flutter/ui/me_page.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_resume_wait_page.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';
import 'package:pocketworld_flutter/ui/sparse_thumbnail.dart';

/// 最小合法 PLY(64 点,真彩)。
Future<String> writePly(String dir) async {
  const n = 64;
  final head =
      'ply\nformat binary_little_endian 1.0\nelement vertex $n\n'
      'property float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\n'
      'end_header\n';
  final body = BytesBuilder();
  for (var i = 0; i < n; i++) {
    final bd = ByteData(15);
    bd.setFloat32(0, (i % 9) * 0.02, Endian.little);
    bd.setFloat32(4, (i % 7) * 0.02, Endian.little);
    bd.setFloat32(8, (i % 5) * 0.02, Endian.little);
    bd.setUint8(12, 180);
    bd.setUint8(13, 120);
    bd.setUint8(14, 90);
    body.add(bd.buffer.asUint8List());
  }
  final f = File('$dir/official_sfm_sparse.ply');
  await f.writeAsBytes([...head.codeUnits, ...body.toBytes()], flush: true);
  return f.path;
}

void main() {
  group('胶囊升格 draftBadgeWithResume', () {
    test('续跑在飞 + 本来"未完成" ⇒ 升格"生成中"', () {
      expect(
        draftBadgeWithResume(
          ScanProcessingBadge.unfinished,
          resumeInFlight: true,
        ),
        ScanProcessingBadge.generating,
        reason: '不升格 ⇒ 续跑期间用户看到红色"未完成",且轮询不开、完成后也不刷新',
      );
    });
    test('没在飞 ⇒ 原样("未完成"就该是"未完成")', () {
      expect(
        draftBadgeWithResume(
          ScanProcessingBadge.unfinished,
          resumeInFlight: false,
        ),
        ScanProcessingBadge.unfinished,
      );
    });
    test('已完成/无胶囊不受在飞影响(重新重建入口不该把"完成"改回"生成中"之外的东西)', () {
      // "重新重建"(regenerate)期间 PLY 还在,badgeOf 不会给 unfinished ——
      // 升格只对 unfinished 生效,其余原样透传。
      for (final b in [
        ScanProcessingBadge.none,
        ScanProcessingBadge.generating,
        ScanProcessingBadge.done,
      ]) {
        expect(draftBadgeWithResume(b, resumeInFlight: true), b);
        expect(draftBadgeWithResume(b, resumeInFlight: false), b);
      }
    });
  });

  group('按目录名查在飞(容器 UUID 变了也要命中)', () {
    test('旧容器绝对路径 + 新容器在飞 ⇒ 按目录名命中', () {
      const dirName = 'cap_123';
      official.debugSetResumeInFlight(
        '/var/mobile/NEW-UUID/Documents/captures_official/$dirName',
        inFlight: true,
      );
      addTearDown(
        () => official.debugSetResumeInFlight(
          '/var/mobile/NEW-UUID/Documents/captures_official/$dirName',
          inFlight: false,
        ),
      );
      expect(official.isResumeInFlightForDirName(dirName), isTrue);
      expect(official.isResumeInFlightForDirName('cap_456'), isFalse);
      expect(official.isResumeInFlightForDirName(''), isFalse);
    });
  });

  group('等待页:成功那一刻就画封面', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('resume_thumb_');
    });
    tearDown(() => dir.delete(recursive: true));

    testWidgets('resume 成功 ⇒ official_sparse_thumb.png 已在盘上', (tester) async {
      late String ply;
      await tester.runAsync(() async {
        ply = await writePly(dir.path);
      });
      expect(File(ply).existsSync(), isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: SfmResumeWaitPage(
            captureDir: dir.path,
            title: '未命名(6)',
            runner: (_) async => true,
          ),
        ),
      );
      // 离屏渲染是真实异步 I/O —— 必须 runAsync。
      await tester.runAsync(() async {
        for (var i = 0; i < 100; i++) {
          if (File(sparseThumbPathFor(dir.path)).existsSync()) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();

      final thumb = File(sparseThumbPathFor(dir.path));
      expect(
        thumb.existsSync() && thumb.lengthSync() > 0,
        isTrue,
        reason:
            '等待页 resume 成功后没画封面 ⇒ 用户回到草稿页看到的还是照片,'
            '要等 2 秒轮询懒补才跳变',
      );
      // PNG magic。
      expect(thumb.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    testWidgets('resume 失败 ⇒ 不画封面(没有点云,别糊一张旧图)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SfmResumeWaitPage(
            captureDir: dir.path,
            title: '未命名(6)',
            runner: (_) async => false,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(File(sparseThumbPathFor(dir.path)).existsSync(), isFalse);
    });
  });
}
