// 契约测试:lib/vio/ffi/xrslam_status.dart 的常量必须与 C 头逐条一致。
//
// 为什么需要它:ffigen 的宏求值器在 XRSLAM.h 上整批失败,所以那九个返回码是
// **手写**的。手写就会漂 —— 头里改了值、这边没跟,是最典型的静默失效
// (Dart 侧把 -5「通道被编译掉」当成 -4「内部错误」处理,永远查不出来)。
//
// 这个测试把 C 头当唯一真源:解析它,逐条对拍。头改了这边没跟,当场红。
//
// ⚠️ 它依赖 xrslam 仓库的路径。CI 上必须设 XRSLAM_ROOT,否则会 skip ——
//    而 **skip 不是通过**,所以这里把「找不到头」也做成一条显式失败的断言,
//    只有明确设了 XRSLAM_SKIP_CONTRACT=1 才允许跳过。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_status.dart';

/// 从 C 头里解析 `#define XRSLAM_XXX <int>` / `(-N)` / `((unsigned char)0xNN)`。
Map<String, int> parseHeaderMacros(String source) {
  final Map<String, int> out = <String, int>{};
  final RegExp re = RegExp(
    r'^\s*#define\s+(XRSLAM_[A-Z0-9_]+)\s+(.+?)\s*(?:/\*.*)?$',
    multiLine: true,
  );
  for (final RegExpMatch m in re.allMatches(source)) {
    final String name = m.group(1)!;
    String v = m.group(2)!.trim();
    // 剥掉尾随注释与外层括号、强制转换
    v = v.replaceAll(RegExp(r'/\*.*?\*/'), '').trim();
    v = v.replaceAll(RegExp(r'\(\s*unsigned\s+char\s*\)'), '').trim();
    while (v.startsWith('(') && v.endsWith(')')) {
      v = v.substring(1, v.length - 1).trim();
    }
    final int? parsed = v.startsWith('0x') || v.startsWith('0X')
        ? int.tryParse(v.substring(2), radix: 16)
        : int.tryParse(v);
    if (parsed != null) out[name] = parsed;
  }
  return out;
}

File? _locateHeader() {
  final String? root = Platform.environment['XRSLAM_ROOT'];
  final List<String> candidates = <String>[
    if (root != null) '$root/xrslam-interface/include/XRSLAM.h',
    '${Platform.environment['HOME']}/Developer/xrslam'
        '/xrslam-interface/include/XRSLAM.h',
    '../xrslam/xrslam-interface/include/XRSLAM.h',
  ];
  for (final String p in candidates) {
    final File f = File(p);
    if (f.existsSync()) return f;
  }
  return null;
}

void main() {
  group('XRSLAM 返回码契约(C 头 = 唯一真源)', () {
    test('手写常量与 C 头逐条一致', () {
      final File? header = _locateHeader();
      if (header == null) {
        // skip 不是通过 —— 只有显式声明才允许跳过。
        expect(
          Platform.environment['XRSLAM_SKIP_CONTRACT'],
          '1',
          reason: '找不到 XRSLAM.h。设 XRSLAM_ROOT 指向 xrslam 仓库,'
              '或显式设 XRSLAM_SKIP_CONTRACT=1 才允许跳过。'
              'CI 上静默 skip 等于这条契约没人守。',
        );
        return;
      }

      final Map<String, int> fromHeader =
          parseHeaderMacros(header.readAsStringSync());

      expect(fromHeader, isNotEmpty, reason: '解析 C 头没拿到任何宏 —— 解析器坏了');

      final List<String> mismatches = <String>[];
      kXrslamStatusContract.forEach((String name, int dartValue) {
        if (!fromHeader.containsKey(name)) {
          mismatches.add('$name: C 头里已不存在,但 Dart 侧还留着 $dartValue');
        } else if (fromHeader[name] != dartValue) {
          mismatches.add('$name: C 头=${fromHeader[name]} vs Dart=$dartValue');
        }
      });
      // 反向:头里新增了返回码而 Dart 侧没跟
      for (final String name in fromHeader.keys) {
        if (name.startsWith('XRSLAM_ERR_') ||
            name == 'XRSLAM_OK' ||
            name == 'XRSLAM_INCOMPLETE' ||
            name == 'XRSLAM_NO_NEW_DATA') {
          if (!kXrslamStatusContract.containsKey(name)) {
            mismatches.add('$name: C 头新增了返回码,Dart 侧未同步');
          }
        }
      }

      expect(mismatches, isEmpty,
          reason: '返回码漂了:\n  ${mismatches.join("\n  ")}');
    });

    test('XRSLAMCreate 的反向约定不能用 xrslamSucceeded 判', () {
      // 上游遗留:1=成功 / 0=失败。用常规判据会把「失败」当「成功」。
      expect(xrslamCreateSucceeded(1), isTrue);
      expect(xrslamCreateSucceeded(0), isFalse);
      // 这正是危险点:0 在常规约定里是 OK
      expect(xrslamSucceeded(0), isTrue);
    });

    test('非错误状态与错误分得开', () {
      expect(xrslamSucceeded(xrslamOk), isTrue);
      expect(xrslamSucceeded(xrslamIncomplete), isTrue);
      expect(xrslamSucceeded(xrslamErrBadArg), isFalse);
      expect(xrslamIsPartial(xrslamIncomplete), isTrue);
      expect(xrslamIsPartial(xrslamOk), isFalse);
    });

    test('通道被编译掉必须与内部错误分开', () {
      // 混淆这两个 = 把一个可诊断的配置问题当成不可诊断的内部故障
      expect(xrslamIsUnavailable(xrslamErrUnavailable), isTrue);
      expect(xrslamIsUnavailable(xrslamErrInternal), isFalse);
    });

    test('未知码不被吞掉', () {
      expect(xrslamStatusName(-99), contains('-99'));
    });

    test('解析器本身:能吃各种写法', () {
      final Map<String, int> m = parseHeaderMacros('''
#define XRSLAM_OK                0
#define XRSLAM_INCOMPLETE        1  /*!< 注释 */
#define XRSLAM_ERR_BAD_ARG      (-1)
#define XRSLAM_LANDMARK_FLAG_TRIANGULATED  ((unsigned char)0x01)
''');
      expect(m['XRSLAM_OK'], 0);
      expect(m['XRSLAM_INCOMPLETE'], 1);
      expect(m['XRSLAM_ERR_BAD_ARG'], -1);
      expect(m['XRSLAM_LANDMARK_FLAG_TRIANGULATED'], 1);
    });
  });
}
