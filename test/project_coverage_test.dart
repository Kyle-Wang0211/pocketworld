// 「db 覆盖了盘上所有照片吗」判据的契约 —— 固定件是**真机账本原文**。
//
// [2026-09-11] 起因是用户实机指认:「未命名(8) 分两次拍(20+5),前 20 帧好像
// 没参与训练」。查实:26 张里 20 张颗粒无收 —— 交付的云 n_registered=6、
// 4538 点,而第一次拍摄当时屏幕上的实时云是 12808 点 / 14 帧。
//
// 光靠 sqlite_db_health 那条判据挡不住:事后那个 db **头完全自洽**
// (3032 页对 3032 页)。它只是「健全但只装了 6 张」。所以要有这第二条腿。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/archived_photo_rebuild.dart';

/// 真机 `cap_1789105782936554`(未命名(8))的 official_sfm_fed_frames.jsonl,
/// 只留 frameId + 文件名。20 行:第一次拍摄喂进去 14 帧(frameId 0-13),
/// 补拍又从 **frameId 0** 重新数了 6 帧 —— 0-5 各出现两次。
const List<String> kUnnamed8Ledger = <String>[
    '{"frameId":0,"jpegPath":"official_tap-2.jpg"}',
    '{"frameId":1,"jpegPath":"official_tap-18.jpg"}',
    '{"frameId":2,"jpegPath":"official_tap-32.jpg"}',
    '{"frameId":3,"jpegPath":"official_tap-40.jpg"}',
    '{"frameId":4,"jpegPath":"official_tap-48.jpg"}',
    '{"frameId":5,"jpegPath":"official_tap-58.jpg"}',
    '{"frameId":6,"jpegPath":"official_tap-74.jpg"}',
    '{"frameId":7,"jpegPath":"official_tap-85.jpg"}',
    '{"frameId":8,"jpegPath":"official_tap-113.jpg"}',
    '{"frameId":9,"jpegPath":"official_tap-124.jpg"}',
    '{"frameId":10,"jpegPath":"official_tap-139.jpg"}',
    '{"frameId":11,"jpegPath":"official_tap-132.jpg"}',
    '{"frameId":12,"jpegPath":"official_tap-164.jpg"}',
    '{"frameId":13,"jpegPath":"official_tap-196.jpg"}',
    '{"frameId":0,"jpegPath":"official_tap-219.jpg"}',
    '{"frameId":1,"jpegPath":"official_tap-257.jpg"}',
    '{"frameId":2,"jpegPath":"official_tap-263.jpg"}',
    '{"frameId":3,"jpegPath":"official_tap-277.jpg"}',
    '{"frameId":4,"jpegPath":"official_tap-295.jpg"}',
    '{"frameId":5,"jpegPath":"official_tap-303.jpg"}',
];

/// 盘上真实的 26 张照片(设备清单读出来的帧序号)。
const List<int> kUnnamed8DiskSeqs = <int>[
  2, 18, 32, 40, 48, 58, 74, 85, 97, 105, 113, 124, 132, 139, 164, 173, 180, 188, 196, 208, 219, 257, 263, 277, 295, 303,
];

/// 真机 `cap_1789045251403847`(未命名(5))—— 一次拍完、20 张、账本干净。
const List<String> kUnnamed5Ledger = <String>[
    '{"frameId":0,"jpegPath":"official_tap-1.jpg"}',
    '{"frameId":1,"jpegPath":"official_tap-8.jpg"}',
    '{"frameId":2,"jpegPath":"official_tap-39.jpg"}',
    '{"frameId":3,"jpegPath":"official_tap-62.jpg"}',
    '{"frameId":4,"jpegPath":"official_tap-77.jpg"}',
    '{"frameId":5,"jpegPath":"official_tap-86.jpg"}',
    '{"frameId":6,"jpegPath":"official_tap-94.jpg"}',
    '{"frameId":7,"jpegPath":"official_tap-103.jpg"}',
    '{"frameId":8,"jpegPath":"official_tap-109.jpg"}',
    '{"frameId":9,"jpegPath":"official_tap-118.jpg"}',
    '{"frameId":10,"jpegPath":"official_tap-126.jpg"}',
    '{"frameId":11,"jpegPath":"official_tap-134.jpg"}',
    '{"frameId":12,"jpegPath":"official_tap-144.jpg"}',
    '{"frameId":13,"jpegPath":"official_tap-155.jpg"}',
    '{"frameId":14,"jpegPath":"official_tap-167.jpg"}',
    '{"frameId":15,"jpegPath":"official_tap-175.jpg"}',
    '{"frameId":16,"jpegPath":"official_tap-179.jpg"}',
    '{"frameId":17,"jpegPath":"official_tap-187.jpg"}',
    '{"frameId":18,"jpegPath":"official_tap-192.jpg"}',
    '{"frameId":19,"jpegPath":"official_tap-200.jpg"}',
];

String ledger(List<String> lines) => '${lines.join('\n')}\n';
List<String> diskNames(List<int> seqs) =>
    seqs.map((n) => 'official_tap-$n.jpg').toList();

void main() {
  test('🔴真机未命名(8):两条腿各自独立命中', () {
    final c = projectCoverageFrom(
      jpegNamesOnDisk: diskNames(kUnnamed8DiskSeqs),
      fedFramesJsonl: ledger(kUnnamed8Ledger),
    );
    expect(c.photosOnDisk, 26);
    expect(c.fedDistinct, 20);
    expect(c.covered, isFalse);
    // 腿①:盘上 6 张从没进过账本。
    expect(c.neverFed.length, 6);
    // 腿②:frameId 0-5 各出现两次 ⇒ 重复 6 次。
    expect(c.duplicateFrameIds, 6);
    expect(c.reason, contains('6 张没喂过'));
    expect(c.reason, contains('frameId 重复'));
  });

  test('🔴两条腿必须各自单独就能判死 —— 不许互相兜底', () {
    // 只留腿②:把盘上照片缩到账本覆盖得到的那 20 张,重复 fid 依然在。
    final onlyDup = projectCoverageFrom(
      jpegNamesOnDisk: kUnnamed8Ledger
          .map((l) => l.split('"jpegPath":"')[1].split('"')[0])
          .toSet()
          .toList(),
      fedFramesJsonl: ledger(kUnnamed8Ledger),
    );
    expect(onlyDup.neverFed, isEmpty, reason: '这一臂把腿①关掉了');
    expect(onlyDup.covered, isFalse, reason: '只剩腿②也必须判死');

    // 只留腿①:账本去重成一份干净的(fid 不重复),但盘上多两张没喂过的。
    final clean = kUnnamed8Ledger.take(14).toList();
    final onlyNeverFed = projectCoverageFrom(
      jpegNamesOnDisk: diskNames(kUnnamed8DiskSeqs),
      fedFramesJsonl: ledger(clean),
    );
    expect(onlyNeverFed.duplicateFrameIds, 0, reason: '这一臂把腿②关掉了');
    expect(onlyNeverFed.covered, isFalse, reason: '只剩腿①也必须判死');
  });

  test('🔴阴性对照:真机六个健康项目里的一个,必须判"覆盖齐"', () {
    // 判据要是只会喊"不齐",它就没有判别力 —— 每个项目都会被推去全量重喂。
    final seqs = kUnnamed5Ledger
        .map((l) => l.split('"jpegPath":"')[1].split('"')[0])
        .toList();
    final c = projectCoverageFrom(
      jpegNamesOnDisk: seqs,
      fedFramesJsonl: ledger(kUnnamed5Ledger),
    );
    expect(c.photosOnDisk, 20);
    expect(c.fedDistinct, 20);
    expect(c.duplicateFrameIds, 0);
    expect(c.covered, isTrue);
    expect(c.reason, isNull);
  });

  test('账本缺失/空 ⇒ 判不齐(没有证据就不能说"db 里有全部照片")', () {
    final c = projectCoverageFrom(
      jpegNamesOnDisk: <String>['official_tap-1.jpg'],
      fedFramesJsonl: '',
    );
    expect(c.covered, isFalse);
    expect(c.neverFed, <String>['official_tap-1.jpg']);
  });

  test('坏行不让整条判据崩,但也不算数', () {
    final c = projectCoverageFrom(
      jpegNamesOnDisk: <String>['a.jpg', 'b.jpg'],
      fedFramesJsonl:
          '{"frameId":0,"jpegPath":"/x/a.jpg"}\n{ 这行不是 json\n'
          '{"frameId":1,"jpegPath":"/x/b.jpg"}\n',
    );
    expect(c.covered, isTrue, reason: '两张都在账本里,中间那行坏的不该影响结论');
    expect(c.duplicateFrameIds, 0);
  });

  test('盘上没照片时不该判"不齐"(没照片就没有"没喂过"的)', () {
    final c = projectCoverageFrom(
      jpegNamesOnDisk: const <String>[],
      fedFramesJsonl: '',
    );
    expect(c.neverFed, isEmpty);
    expect(c.covered, isTrue);
  });
}
