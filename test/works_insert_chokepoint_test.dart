// works 表 INSERT 的收口契约。
//
// 为什么需要这一条:publish_service_test.dart 的 25 个用例注入的是接缝
// (uploadModel),它们只断言 PublishException.phase 与 no-orphan —— 把
// `from('works').insert(row)` 换成调用 Edge Function 之后,只要仍返回一个
// work id、仍抛同类错误,那 25 个用例**照样全绿**。换句话说它们对"客户端有没有
// 直连 works 表"这件事是瞎的,而那恰恰是本次收口的全部内容。
//
// 所以这里用源码文本契约钉住结构。仓库已有同款模式:
// test/community_home_restructure_test.dart 直接 readAsStringSync 断言内容。
//
// ⚠️ 判据必须先剥掉注释行。本次收口在 publish_service.dart 里写了大量提到
//    works_insert_own / INSERT public.works 的说明性注释;若判据直接对全文
//    grep,就会匹配到我自己刚写的注释而"自证通过" —— 那种测试比没有更坏。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 去掉 `//` 行注释与块注释,只留可执行代码。
String _codeOnly(String src) {
  final withoutBlock = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlock
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  group('works INSERT 收口契约', () {
    test('publish_service.dart 不得再触碰 works 表', () {
      final code = _codeOnly(
        File('lib/community/publish_service.dart').readAsStringSync(),
      );
      expect(
        code.contains("from('works')"),
        isFalse,
        reason:
            '发布链路必须只经由 upload-finalize 建行。'
            '迁移 20260823020000 撤销了 works_insert_own 并加了 RESTRICTIVE 守卫,'
            '客户端直写会在运行时被 RLS 拒掉 —— 但那是上线后才发现,这里要提前拦住。',
      );
    });

    test('整个 lib/ 里不存在 works 表的 insert 调用', () {
      final offenders = <String>[];
      for (final f
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        // 折成单行再匹配:真实写法是 .from('works')\n  .insert(...) 跨行的。
        final flat = _codeOnly(
          f.readAsStringSync(),
        ).replaceAll(RegExp(r'\s+'), '');
        if (flat.contains(".from('works').insert(")) {
          offenders.add(f.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'works 行只能由 upload-finalize(service_role)创建。'
            '这些文件在直接 INSERT:$offenders',
      );
    });

    test('upload-finalize 显式写入 under_review —— 漏写就是默认放行', () {
      final src = File(
        'supabase/functions/upload-finalize/index.ts',
      ).readAsStringSync();
      // moderation_status 的 DB default 是 'ok'(20260817000000)。
      // 建行时不显式写 under_review,新作品就直接可见 —— 静默的安全洞。
      expect(
        src.contains("moderation_status: 'under_review'"),
        isTrue,
        reason: 'works.moderation_status 的 default 是 ok,建行必须显式覆盖它',
      );
      expect(
        src.contains('published_at: null'),
        isTrue,
        reason:
            'published_at 必须留空,否则作者自己的 feed 会看到待审作品'
            '(feed 查询靠 .not(published_at, is, null) 过滤)',
      );
    });

    test('upload-finalize 显式查 kill switch —— service_role 绕过 RLS', () {
      final src = File(
        'supabase/functions/upload-finalize/index.ts',
      ).readAsStringSync();
      expect(
        src.contains("rpc('uploads_enabled')"),
        isTrue,
        reason:
            'kill_switch_works_write 是 for insert to authenticated,'
            '收口后 INSERT 由 service_role 执行会绕过它。'
            '不显式查开关,等于把运营手里的刹车拆了。',
      );
    });
  });
}
