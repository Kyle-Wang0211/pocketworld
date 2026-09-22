// ios_exported_symbol_whitelist_contract_test.dart
//
// ══ 这条测试在防什么 ═══════════════════════════════════════════════════════
// `ios/Runner.xcodeproj/project.pbxproj` 的 `OTHER_LDFLAGS` 里有一串
// `-Wl,-exported_symbol,_xxx`。ld64 的语义是:**只要出现一个
// `-exported_symbol`,导出表就变成排他的白名单** —— 没列进去的符号会被从
// 主二进制的动态符号表里摘掉。
//
// 而 `DynamicLibrary.process()`(= `dlopen(NULL)` + `dlsym`)**只找得到导出
// 的符号**。⇒ 任何一个 Dart 按名字查、又定义在 Runner 里的符号,只要不在
// 这张名单上,`lookupFunction` 就会失败 —— 而且失败得很安静:仓里每一处
// FFI 门面都按「符号不在 = 功能降级」处理,不抛、不报警。
//
// 🔴 这不是假想。2026-09-18 的 `a9378db`(「ios: camera frame slot, reachable
//    from Dart over FFI」)第一次引入这串 flag,只列了 6 个
//    `pw_camera_slot_*`。那一刀把导出表从「全导出」变成了「只导出这 6 个」,
//    于是 `pw_jxl_*` / `pw_zpaq_*` 这些**早就在用**的符号一起被关掉了。
//    加白名单的人只想让自己的新符号可达,没意识到这个 flag 是排他的。
//
// ⇒ 所以判据不能是「我记得加了哪些」,必须是一条可核的规则:
//
//      白名单 ⊇ ( Dart 在 lib/ 里按名字查的符号 ∩ Runner target 自己定义的符号 )
//
// 两边都是从源码 grep 出来的,不是手抄的列表 —— 新加一个 @_cdecl 又在 Dart
// 里查它、却忘了加白名单,这条测试当场红,并把缺的名字打出来。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 仓根。测试的工作目录是包根,`ios/` 就在旁边。
final Directory _repo = Directory.current;

File _f(String rel) => File('${_repo.path}/$rel');

/// Dart 侧按名字查的符号:`.lookup<…>('name')` / `.lookupFunction<…>('name')`。
final RegExp _dartLookup = RegExp(
  r"""\.\s*lookup(?:Function)?\s*<.*?>\s*\(\s*['"]([A-Za-z_][A-Za-z0-9_]*)['"]""",
  dotAll: true,
);

/// Swift 侧的 C 链接出口。
final RegExp _cdecl = RegExp(r'@_cdecl\("([A-Za-z_][A-Za-z0-9_]*)"\)');

Set<String> _dartLookedUpSymbols() {
  final out = <String>{};
  final lib = Directory('${_repo.path}/lib');
  for (final e in lib.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    for (final m in _dartLookup.allMatches(e.readAsStringSync())) {
      out.add(m.group(1)!);
    }
  }
  return out;
}

Set<String> _runnerCdeclSymbols() {
  final out = <String>{};
  final dir = Directory('${_repo.path}/ios/Runner');
  for (final e in dir.listSync()) {
    if (e is! File || !e.path.endsWith('.swift')) continue;
    for (final m in _cdecl.allMatches(e.readAsStringSync())) {
      out.add(m.group(1)!);
    }
  }
  return out;
}

void main() {
  final File pbx = _f('ios/Runner.xcodeproj/project.pbxproj');

  group('iOS 导出符号白名单', () {
    late String proj;
    late Set<String> exported;

    setUpAll(() {
      proj = pbx.readAsStringSync();
      exported = RegExp(r'-Wl,-exported_symbol,_([A-Za-z_0-9]+)')
          .allMatches(proj)
          .map((m) => m.group(1)!)
          .toSet();
    });

    test('pbxproj 在,而且确实用了排他的 -exported_symbol', () {
      expect(pbx.existsSync(), isTrue);
      expect(
        exported,
        isNotEmpty,
        reason: '如果哪天把 -exported_symbol 全删了(= 恢复默认全导出),'
            '这条测试就该被删掉,而不是留着假装还在防什么',
      );
    });

    test('🔴 每一个「Dart 查 + Runner 的 @_cdecl 定义」的符号都在白名单上', () {
      final Set<String> dart = _dartLookedUpSymbols();
      final Set<String> cdecl = _runnerCdeclSymbols();
      expect(dart, isNotEmpty, reason: 'grep 不到任何 Dart FFI 查找 —— 正则坏了');
      expect(cdecl, isNotEmpty, reason: 'grep 不到任何 @_cdecl —— 正则坏了');

      final Set<String> required = dart.intersection(cdecl);
      final missing = required.difference(exported).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: '这些符号 Dart 会按名字查、Runner 也定义了,但**没在导出白名单上**'
            ' ⇒ Release 里 DynamicLibrary.process() 查不到,功能会安静地降级:\n'
            '  ${missing.join('\n  ')}\n'
            '修法:在 ios/Runner.xcodeproj/project.pbxproj 的三处 OTHER_LDFLAGS 里'
            '各加一行 "-Wl,-exported_symbol,_<符号名"(以及配套的 "-Wl,-u,_<符号名>")。',
      );
    });

    test('三份构建配置(Debug/Release/Profile)的白名单完全一致', () {
      // 只在 Release 上加而 Debug 上忘了(或反过来)= 一个只在某一档复现的 bug,
      // 那是最难查的一类。
      final blocks = <List<String>>[];
      List<String>? cur;
      for (final line in proj.split('\n')) {
        if (line.contains('OTHER_LDFLAGS = (')) {
          cur = <String>[];
          blocks.add(cur);
        } else if (cur != null) {
          final m =
              RegExp(r'-Wl,-exported_symbol,_([A-Za-z_0-9]+)').firstMatch(line);
          if (m != null) cur.add(m.group(1)!);
          if (line.trim() == ');') cur = null;
        }
      }
      final withList = blocks.where((b) => b.isNotEmpty).toList();
      expect(withList.length, 3, reason: 'OTHER_LDFLAGS 带白名单的块不是 3 个');
      for (int i = 1; i < withList.length; i++) {
        expect(
          withList[i].toSet(),
          withList[0].toSet(),
          reason: '第 ${i + 1} 个 OTHER_LDFLAGS 块的白名单与第 1 个不一致',
        );
      }
    });

    test('白名单里的每个符号都真的被某处定义(防拼错/防写一个不存在的名字)', () {
      // ld64 对「导出一个不存在的符号」只会警告,不会失败 ⇒ 拼错不会显形。
      final Set<String> cdecl = _runnerCdeclSymbols();
      final unknown = <String>[];
      for (final s in exported) {
        if (cdecl.contains(s)) continue;
        // 非 Swift 的那几类:C/C++ bridge 编进 Runner 的 Sources。
        if (s.startsWith('pw_jxl_') || s.startsWith('pw_zpaq_')) continue;
        unknown.add(s);
      }
      unknown.sort();
      expect(
        unknown,
        isEmpty,
        reason: '白名单里这些符号在 ios/Runner 的 @_cdecl / jxl / zpaq 里都找不到定义:\n'
            '  ${unknown.join('\n  ')}',
      );
    });
  });

  group('pbxproj 的 UUID', () {
    test('🔴 没有两个对象共用同一个 24 位 UUID', () {
      // ══ 这条是被一次真实的构建失败逼出来的 ══════════════════════════════
      // 2026-09-22:两位 agent 在各自的分支上给自己的新 Swift 文件挑 UUID,
      // 都挑了 `0F1C1A10000000000000C001` / `…C011`。两条分支的 pbxproj 改动
      // **文本上不冲突**,git 一声不响地 auto-merge 了,`plutil -lint` 也说 OK。
      // 结果 Xcode 把两个 `in Sources` 条目解析成同一个 build file ⇒
      // 其中一个文件**根本没被编译**,报出来的是
      //     Error (Xcode): Undefined symbol: _pw_vio_pose_source
      // —— 离真正的病因(UUID 撞车)隔着三层。
      //
      // 🔴 当时唯一抓到它的是**真机 Release 构建**;analyze / 单测 / plutil
      //    全都是绿的。所以把它固化成一条离线可跑的判据。
      final String proj = pbx.readAsStringSync();
      final Map<String, List<String>> byId = <String, List<String>>{};
      // 只认**对象定义**行:两个 tab 缩进 + `= {isa = `。
      // 🔴 不能用 `^\s*` —— `PBXProject.attributes.TargetAttributes` 里有
      //    `\t\t\t\t\tUUID = {` 这种**引用**,它复用 target 的 UUID 是合法的,
      //    误判成重复会让这条测试永远红。`isa =` 是「这是个对象定义」的判据。
      final re = RegExp(
        r'^\t\t([0-9A-F]{24})\s*(?:/\* (.*?) \*/)?\s*=\s*\{isa = ',
        multiLine: true,
      );
      for (final m in re.allMatches(proj)) {
        byId.putIfAbsent(m.group(1)!, () => <String>[]).add(m.group(2) ?? '?');
      }
      expect(byId, isNotEmpty, reason: '一个对象定义都没 grep 到 —— 正则坏了');
      final dupes = <String>[];
      byId.forEach((id, names) {
        if (names.length > 1) dupes.add('$id ← ${names.join(" / ")}');
      });
      dupes.sort();
      expect(
        dupes,
        isEmpty,
        reason: '这些 UUID 被多个对象共用,Xcode 会只认其中一个 ⇒ 另一个文件'
            '不会被编译/链接(报出来的是莫名其妙的 Undefined symbol):\n'
            '  ${dupes.join("\n  ")}',
      );
    });
  });

  group('🔴 已知缺口(本测试只记录,不判红)', () {
    test('pw_sqlite_* / pw_lepton_* 的实现根本不在 Runner target 里', () {
      // 这两组符号 Dart 也是按名字查的(database_prune_ffi.dart 等),
      // 但它们**不该**被加进导出白名单 —— 因为它们压根没被编进/链进 Runner:
      //   · ios/Runner/pw_sqlite_descriptor_transform.cpp 文件在,
      //     但 pbxproj 里零命中(没进 Sources build phase);
      //   · vendor/lepton_jpeg/libs/ios-arm64/libpw_lepton_jpeg_ffi.a 只是
      //     一个 PBXFileReference + 在分组里,没进 Frameworks build phase。
      // 导出一个不存在的符号救不了它们;那是另一条要单独修的缺口。
      // 这条测试把「我查过了,结论是这样」钉在这里,免得下一个人再查一遍。
      final proj = pbx.readAsStringSync();
      expect(
        proj.contains('pw_sqlite_descriptor_transform.cpp in Sources'),
        isFalse,
        reason: '如果哪天它被加进 Sources 了,那 pw_sqlite_* 就**应该**一起'
            '加进导出白名单 —— 请更新上面那条 required 集合的口径',
      );
      expect(
        proj.contains('libpw_lepton_jpeg_ffi.a in Frameworks'),
        isFalse,
        reason: '同上,lepton 一旦真的被链进来,pw_lepton_* 也要进白名单',
      );
    });
  });
}
