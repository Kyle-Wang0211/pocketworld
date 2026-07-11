// tool/photo_slot_naming_check.dart — 槽位照片唯一文件名纯 Dart VM 断言
// (host `dart tool/photo_slot_naming_check.dart`;flutter test 在此 host
// 跑不了,纯 VM 能跑 —— 项目惯例同 tool/shutter_backpressure_check.dart)。
//
// 复现 cap47 法医病理:cell_90/slot_1 被 6 个 frameId(66/104/106/109/
// 112/114)先后重拍。旧规则同名覆盖 → fed jsonl 里 6 条记录指向同一个
// 文件、内容只剩最后一拍(25/121 帧陈旧染色);新规则(frameId 后缀)
// 每条 fed 记录必须指向内容正确的独立文件。

import 'dart:convert';
import 'dart:io';

import 'package:pocketworld_flutter/capture/photo_slot_naming.dart';

void check(bool cond, String what) {
  if (!cond) {
    throw StateError('FAIL: $what');
  }
  // ignore: avoid_print
  print('ok: $what');
}

void main() {
  final tmp = Directory.systemTemp.createTempSync('photo_slot_naming_check_');
  try {
    final photosDir = Directory('${tmp.path}/photos_highres')
      ..createSync(recursive: true);
    final fedJsonl = File('${tmp.path}/sfm_fed_frames.jsonl');

    // ── 模拟拍摄期:cap47 的 cell_90/slot_1 六次重拍(生产落盘链同形:
    //    生成路径 → 写 JPEG 内容 → fed jsonl 追加该路径)────────────────
    const cellIdx = 90;
    const slotIdx = 1;
    const frameSeqs = [66, 104, 106, 109, 112, 114];
    final pathByFrame = <int, String>{};
    for (final seq in frameSeqs) {
      final base = photoSlotBaseName(
        cellIdx: cellIdx,
        slotIdx: slotIdx,
        frameId: 'tap-$seq',
      );
      final jpegPath = '${photosDir.path}/$base.jpg';
      // 每帧内容不同(真实世界:不同时刻的 4K JPEG)。
      File(jpegPath).writeAsStringSync('JPEG-CONTENT-OF-FRAME-$seq');
      File('${photosDir.path}/$base.json')
          .writeAsStringSync('{"frameSeq":$seq}');
      fedJsonl.writeAsStringSync(
        '${jsonEncode({'frameId': seq, 'jpegPath': jpegPath})}\n',
        mode: FileMode.append,
      );
      pathByFrame[seq] = jpegPath;
    }

    // ── 断言 1:6 条 fed 记录 → 6 个互不相同的路径(旧规则=1 个)──────
    final uniquePaths = pathByFrame.values.toSet();
    check(
      uniquePaths.length == frameSeqs.length,
      '重拍 ${frameSeqs.length} 次 → ${frameSeqs.length} 个独立文件名'
      '(实际 ${uniquePaths.length})',
    );

    // ── 断言 2:每条 fed jsonl 的 jpegPath 存在且内容正确(colorize 视角)─
    for (final line in fedJsonl.readAsLinesSync()) {
      final m = jsonDecode(line) as Map<String, Object?>;
      final fid = m['frameId'] as int;
      final jpeg = m['jpegPath'] as String;
      check(File(jpeg).existsSync(), 'fed frameId=$fid 的文件存在');
      check(
        File(jpeg).readAsStringSync() == 'JPEG-CONTENT-OF-FRAME-$fid',
        'fed frameId=$fid 取到的内容 = 喂入时刻的内容(无陈旧染色)',
      );
    }

    // ── 断言 3:resume 的 basename 重join(sfm_resume._loadFrameMeta 同款)
    //    在换 App 容器 UUID 后仍解析到同一独立文件 ─────────────────────
    for (final line in fedJsonl.readAsLinesSync()) {
      final m = jsonDecode(line) as Map<String, Object?>;
      final fid = m['frameId'] as int;
      final rejoined =
          '${photosDir.path}/${(m['jpegPath'] as String).split('/').last}';
      check(
        File(rejoined).readAsStringSync() == 'JPEG-CONTENT-OF-FRAME-$fid',
        'resume basename 重join frameId=$fid 内容正确',
      );
    }

    // ── 断言 4:sidecar .json 与 .jpg 共基名(prune 的 .json→.jpg 配对
    //    规则依赖此不变量)─────────────────────────────────────────────
    for (final p in pathByFrame.values) {
      final sidecar = '${p.substring(0, p.length - '.jpg'.length)}.json';
      check(File(sidecar).existsSync(), 'sidecar 共基名存在: ${sidecar.split('/').last}');
    }

    // ── 断言 5:老采集兼容 —— 旧式名(无 frameId 后缀)的 fed 记录按同一
    //    basename 重join 规则解析,不崩、内容正确(resume 读旧包)────────
    final legacyPath = '${photosDir.path}/cell_90_slot_1.jpg';
    File(legacyPath).writeAsStringSync('LEGACY-JPEG-CONTENT');
    final legacyLine = jsonEncode({'frameId': 0, 'jpegPath': legacyPath});
    final lm = jsonDecode(legacyLine) as Map<String, Object?>;
    final legacyRejoined =
        '${photosDir.path}/${(lm['jpegPath'] as String).split('/').last}';
    check(
      File(legacyRejoined).readAsStringSync() == 'LEGACY-JPEG-CONTENT',
      '老采集旧式文件名 resume 重join 兼容',
    );

    // ── 断言 6(反证):旧规则会把 6 帧塌缩到 1 个路径 —— 证明 bug 面
    //    确实被 frameId 后缀关闭 ─────────────────────────────────────────
    final legacyCollapsed = frameSeqs
        .map((_) => '${photosDir.path}/cell_${cellIdx}_slot_$slotIdx.jpg')
        .toSet();
    check(
      legacyCollapsed.length == 1 && uniquePaths.length == frameSeqs.length,
      '旧规则 6 帧塌缩为 1 路径(bug),新规则 6 路径(已关闭)',
    );

    // ignore: avoid_print
    print('ALL PASS');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}
