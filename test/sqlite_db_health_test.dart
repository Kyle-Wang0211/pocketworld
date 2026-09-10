// 「db 还能不能开」判据的契约 —— 用**真机字节**当固定件。
//
// 两个 fixture 都是 2026-09-08 从设备/主机上原样取的前 100 字节:
//   dead    = 真机 cap_1788845271610360 被杀后留下的 official_sfm_live.db
//             (整个文件只有 4096 字节;`sqlite3 .tables` 报 malformed)
//   healthy = 同一批照片在 Mac 上重新喂帧跑完 finalize 得到的库
//             (25608192 字节;11 张表全在)
// 自造头会对"我没读到的规则"失明,所以这里只用真字节。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/sqlite_db_health.dart';

Uint8List hex(String s) {
  // 固定件抄错一位会让整条判据静默退化成"降级为可用"(头看不懂就放行)——
  // 那样测试会全绿而判据其实没跑。所以先钉死长度。
  expect(s.length, 200, reason: 'db 头固定件必须正好 100 字节');
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 真机残骸的头 100 字节。page_size=4096,in-header 页数=0x0bd1=3025,
/// change counter=9 == version-valid-for=9(⇒ 该字段可信),而文件只有 4096 字节。
const String kDeadHeaderHex =
    '53514c69746520666f726d617420330010000202004020200000000900000bd1'
    '00000000000000000000001000000004000000000000000000000001003d3010'
    '0000000000000000000000000000000000000000000000000000000000000009'
    '002e8df8';

/// 健康库的头 100 字节。in-header 页数=0x186c=6252,文件 25608192/4096=6252。
const String kHealthyHeaderHex =
    '53514c69746520666f726d617420330010000202004020200000000c0000186c'
    '00000000000000000000001000000004000000000000000000000001003d3010'
    '000000000000000000000000000000000000000000000000000000000000000c'
    '002e8df8';

void main() {
  test('真机残骸:头声称 3025 页、文件只有 1 页 ⇒ 判为不可用', () {
    final h = sqliteHeaderUsable(hex(kDeadHeaderHex), fileLength: 4096);
    expect(h.usable, isFalse);
    expect(h.reason, contains('3025'));
    expect(h.reason, contains('1 页'));
  });

  test('健康库:头页数与文件页数一致 ⇒ 可用', () {
    final h = sqliteHeaderUsable(hex(kHealthyHeaderHex), fileLength: 25608192);
    expect(h.usable, isTrue);
    expect(h.reason, isNull);
  });

  test('🔴阴性对照:判据不是"文件小就坏"', () {
    // 拿健康库的头、配一个"刚好装得下它声称页数"的长度 —— 文件只有 6252 页
    // 的字节数,一页都不多。若判据其实是个大小阈值,这条会被判坏。
    final h = sqliteHeaderUsable(
      hex(kHealthyHeaderHex),
      fileLength: 6252 * 4096,
    );
    expect(h.usable, isTrue, reason: '页数刚好相等不算截断');
    // 再拿**残骸的头**配上它声称的完整长度 —— 同样一份头字节,只是文件够长,
    // 就必须判为可用。⇒ 做判决的是"头 vs 文件"的关系,不是这份头本身。
    final full = sqliteHeaderUsable(
      hex(kDeadHeaderHex),
      fileLength: 3025 * 4096,
    );
    expect(full.usable, isTrue, reason: '同一份头 + 完整文件 ⇒ 不该判坏');
  });

  test('少一页就抓出来 —— 判据的分辨率是页,不是数量级', () {
    final h = sqliteHeaderUsable(
      hex(kHealthyHeaderHex),
      fileLength: (6252 - 1) * 4096,
    );
    expect(h.usable, isFalse);
  });

  test('头不可信(change counter ≠ version-valid-for)时诚实降级为可用', () {
    // 官方 file-format 文档:in-header size 只有在 change counter ==
    // version-valid-for 时才有效。把 version-valid-for 改掉,该字段即失效 ——
    // 这时不许拿它去毙掉用户的数据,必须交给 native 定夺。
    final bytes = hex(kDeadHeaderHex);
    ByteData.sublistView(bytes).setUint32(92, 0xDEADBEEF);
    final h = sqliteHeaderUsable(bytes, fileLength: 4096);
    expect(h.usable, isTrue);
  });

  test('in-header 页数为 0 也降级为可用(旧版 sqlite 从不写这个字段)', () {
    final bytes = hex(kHealthyHeaderHex);
    ByteData.sublistView(bytes).setUint32(28, 0);
    final h = sqliteHeaderUsable(bytes, fileLength: 4096);
    expect(h.usable, isTrue);
  });

  test('不是 sqlite 文件 → 明确判坏并说明', () {
    final bytes = hex(kHealthyHeaderHex);
    bytes[0] = 0x00;
    final h = sqliteHeaderUsable(bytes, fileLength: 25608192);
    expect(h.usable, isFalse);
    expect(h.reason, contains('sqlite'));
  });

  test('头不足 100 字节 → 降级为可用,不当成坏', () {
    final h = sqliteHeaderUsable(Uint8List(50), fileLength: 50);
    expect(h.usable, isTrue);
  });
}
