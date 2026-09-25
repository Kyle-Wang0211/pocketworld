// 从存档照片重建 —— 解析与判据的断言。
//
// fixture 全部是**真机真实数据**(cap_1788845271610360,那个 db 被杀死的项目),
// 不是我编的数:tap-1 的 extrinsic / intrinsics / 时间戳逐字抄自设备备份。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/archived_photo_rebuild.dart';

/// 真实 sidecar(tap-1),只保留本模块读的键。
const _realExtrinsic = <double>[
  0.008821525610983372, -0.9117061495780945, 0.4107483923435211, 0,
  0.9998619556427002, 0.013828078284859657, 0.009219387546181679, 0,
  -0.014085202477872372, 0.4106103777885437, 0.9117022156715393, 0,
  -0.0011844653636217117, -0.0005786766414530575, -0.001803806982934475, 1,
];
const _realIntrinsics = <double>[
  2845.43896484375, 2845.43896484375, 2022.5914306640625, 1511.7384033203125,
];

String sidecar({
  Object? intrinsics = _realIntrinsics,
  Object? extrinsic = _realExtrinsic,
  Object? imageW = 4032,
  Object? imageH = 3024,
  Object? t = 47901.948525083,
  Object? saveTargetT = 47901.915188958,
  bool dropT = false,
}) {
  final m = <String, dynamic>{
    if (intrinsics != null) 'intrinsics_fxfycxcy': intrinsics,
    if (extrinsic != null) 'extrinsic': extrinsic,
    if (imageW != null) 'image_w': imageW,
    if (imageH != null) 'image_h': imageH,
    if (!dropT) 't': t,
    if (saveTargetT != null) 'save_target_t': saveTargetT,
  };
  return jsonEncode(m);
}

void main() {
  test('真实 sidecar 解析通过,且 extrinsic 原样透传', () {
    final p = parseArchivedPhoto(
      jpegPath: '/x/official_tap-1.jpg',
      sidecarJson: sidecar(),
    );
    expect(p.isAccepted, isTrue, reason: p.failure);
    final i = p.input!;
    expect(i.intrinsics, _realIntrinsics);
    expect(i.imageWidth, 4032);
    expect(i.imageHeight, 3024);
    expect(i.captureTimestamp, 47901.948525083);
    expect(i.triggerTimestamp, 47901.915188958);
    // 🔴 关键:cameraTransform 必须与 sidecar 的 extrinsic **逐值相同**。
    // offerFrame 的契约是"列主序 camera-to-world",而 sidecar 存的正是它
    // (2026-09-08 拿 fed_frames.jsonl 的已知约定对拍,4/4 张误差 0.000000)。
    // 在这里做任何转置/求逆都会让点云歪掉,而且**不会报任何错**。
    expect(i.cameraTransform, _realExtrinsic);
  });

  test('每种缺失都被拒绝,且带得出原因', () {
    final cases = <String, String>{
      '缺 intrinsics_fxfycxcy': sidecar(intrinsics: null),
      '缺 extrinsic': sidecar(extrinsic: null),
      '缺 image_w/image_h': sidecar(imageW: null),
      '缺时间戳': sidecar(dropT: true, saveTargetT: null),
    };
    cases.forEach((want, json) {
      final p = parseArchivedPhoto(jpegPath: '/x/a.jpg', sidecarJson: json);
      expect(p.isAccepted, isFalse, reason: '$want 应该被拒');
      expect(p.failure, contains(want.split('(').first.trim()));
    });
  });

  test('非有限值 / 长度不足 一律拒绝,不放半个矩阵进去', () {
    final short = parseArchivedPhoto(
      jpegPath: '/x/a.jpg',
      sidecarJson: sidecar(extrinsic: _realExtrinsic.sublist(0, 12)),
    );
    expect(short.isAccepted, isFalse);
    final nan = parseArchivedPhoto(
      jpegPath: '/x/a.jpg',
      sidecarJson: sidecar(intrinsics: const [0, 1, 2, 3]),
    );
    expect(nan.isAccepted, isFalse, reason: 'fx=0 必须被 validate 拒');
  });

  // [ENTRY-ANY-4X3 2026-09-25] 原用例「尺寸不是 4032x3024 一律拒绝」:判据改为任意 4:3、
  // 长边 >= 1920(与拍摄期同一 validate)。
  test('尺寸不合判据一律拒绝(复用拍摄期同一 validate)', () {
    for (final (w, h) in const [(1920, 1080), (1440, 1080), (3024, 4032)]) {
      final p = parseArchivedPhoto(
        jpegPath: '/x/a.jpg',
        sidecarJson: sidecar(imageW: w, imageH: h),
      );
      expect(p.isAccepted, isFalse, reason: '${w}x$h');
      expect(p.failure, contains('validate'));
    }
  });

  test('任意 4:3 且长边 >= 1920 都收(ENTRY-ANY-4X3)', () {
    final p = parseArchivedPhoto(
      jpegPath: '/x/a.jpg',
      sidecarJson: sidecar(imageW: 1920, imageH: 1440),
    );
    expect(p.isAccepted, isTrue);
  });

  test('喂帧顺序按帧序号 N,不是字符串序', () {
    // 真值(cap_1788845271610360):tap-99 的 t=47912.88 早于 tap-129 的
    // t=47915.28,而字符串排序会把 "tap-129" 排在 "tap-99" 前面(1 < 9)。
    final a = parseArchivedPhoto(
      jpegPath: '/x/official_tap-99.jpg',
      sidecarJson: sidecar(t: 47912.882782333, saveTargetT: 47912.799443041),
    );
    final b = parseArchivedPhoto(
      jpegPath: '/x/official_tap-129.jpg',
      sidecarJson: sidecar(t: 47915.282953875, saveTargetT: 47915.216282458),
    );
    final ordered = orderForRefeed([b, a]);
    expect(
      ordered.map((p) => p.jpegPath).toList(),
      ['/x/official_tap-99.jpg', '/x/official_tap-129.jpg'],
    );
    // 阴性对照:纯文件名排序会给出相反的顺序 —— 证明这条断言不是白写的。
    final byName = [b, a]..sort((x, y) => x.jpegPath.compareTo(y.jpegPath));
    expect(byName.first.jpegPath, '/x/official_tap-129.jpg');
  });

  test('🔴补拍跨会话:ARKit t 归零也不能排错(真机 cap_1788845271610360)', () {
    // 本函数最初按 `t` 排,是这组真机数字把它推翻的:第一段拍摄 tap-1..182
    // 的 t≈47901(ARKit uptime),补拍进来的 tap-203/226/233 t≈2145 ——
    // 晚 36 分钟拍的,时间戳却小 45000 秒,因为中间重启过、uptime 归零。
    // 按 t 排会把补拍那三张排到**最前面**,而这不会报任何错。
    final last = parseArchivedPhoto(
      jpegPath: '/x/official_tap-182.jpg',
      sidecarJson: sidecar(t: 47921.283351750, saveTargetT: 47921.216282458),
    );
    final extended = parseArchivedPhoto(
      jpegPath: '/x/official_tap-203.jpg',
      sidecarJson: sidecar(t: 2145.694792833, saveTargetT: 2145.661456500),
    );
    final ordered = orderForRefeed([extended, last]);
    expect(
      ordered.map((p) => p.jpegPath).toList(),
      ['/x/official_tap-182.jpg', '/x/official_tap-203.jpg'],
      reason: '补拍的照片必须排在原有照片之后',
    );
    // 阴性对照:按 t 排恰好给出相反答案 —— 证明这条断言抓的就是那个 bug。
    final byT = [extended, last]
      ..sort(
        (x, y) => x.input!.captureTimestamp.compareTo(y.input!.captureTimestamp),
      );
    expect(byT.first.jpegPath, '/x/official_tap-203.jpg');
  });

  test('认不出序号的老式文件名排在最后,但不丢', () {
    final legacy = parseArchivedPhoto(
      jpegPath: '/x/cell_3_slot_1.jpg',
      sidecarJson: sidecar(t: 1.0, saveTargetT: 1.0),
    );
    final normal = parseArchivedPhoto(
      jpegPath: '/x/official_tap-7.jpg',
      sidecarJson: sidecar(t: 999.0, saveTargetT: 999.0),
    );
    final ordered = orderForRefeed([legacy, normal]);
    expect(ordered.length, 2, reason: '少喂一张就少救一张,一张都不许丢');
    expect(ordered.last.jpegPath, '/x/cell_3_slot_1.jpg');
  });

  test('坏 JSON 不抛,只报拒绝', () {
    final p = parseArchivedPhoto(jpegPath: '/x/a.jpg', sidecarJson: '{not json');
    expect(p.isAccepted, isFalse);
    expect(p.failure, contains('解析失败'));
    final arr = parseArchivedPhoto(jpegPath: '/x/a.jpg', sidecarJson: '[]');
    expect(arr.isAccepted, isFalse);
  });
}
