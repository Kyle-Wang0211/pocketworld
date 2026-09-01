// CDN origin rewrite — L2 通用防御的"接缝"。
//
// 这一层存在的理由是部署形态,不是性能:海外与国内因备案要求必须是两套部署,
// 边缘层无法共用(Cloudflare vs 阿里/腾讯)。把资源源站放进配置,是让同一份
// 代码服务两端的接缝 —— 换边缘厂商永远不该意味着改代码。
//
// 因此测试的重点是**安全边界**而非功能:这个机制能改写 app 去哪里取字节,
// 被劫持就是内容替换向量。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/config/endpoint_config.dart';

const _supabase = 'https://tzvwkqmgaourwqrmxbyb.supabase.co';
const _assetUrl = '$_supabase/storage/v1/object/public/works/uid/model.glb';

EndpointConfig _cfg(String? cdn) => EndpointConfig(
  supabaseUrl: _supabase,
  supabaseAnonKey: 'k',
  assetCdnBase: cdn,
  source: EndpointConfigSource.builtin,
);

void main() {
  group('cdnRewrite — 默认路径必须零变化', () {
    test('未配置 CDN 时原样返回', () {
      expect(_cfg(null).cdnRewrite(_assetUrl), _assetUrl);
    });

    test('空字符串等同未配置', () {
      expect(_cfg('').cdnRewrite(_assetUrl), _assetUrl);
    });
  });

  group('cdnRewrite — 只换 origin,路径必须逐字保留', () {
    test('替换 host,保留完整 storage 路径', () {
      final out = _cfg('https://cdn.pocketworld.io').cdnRewrite(_assetUrl);
      expect(
        out,
        'https://cdn.pocketworld.io/storage/v1/object/public/works/uid/model.glb',
      );
    });

    test('带查询串的 URL 不丢参数', () {
      final withQuery = '$_assetUrl?download=1';
      final out = _cfg('https://cdn.pocketworld.io').cdnRewrite(withQuery);
      expect(out.endsWith('/works/uid/model.glb?download=1'), isTrue);
    });

    test('缩略图路径同样只换 origin', () {
      final thumb = '$_supabase/storage/v1/object/public/thumbnails/uid/w.jpg';
      final out = _cfg('https://cdn.pocketworld.io').cdnRewrite(thumb);
      expect(
        out,
        'https://cdn.pocketworld.io/storage/v1/object/public/thumbnails/uid/w.jpg',
      );
    });
  });

  group('cdnRewrite — 安全边界(这才是重点)', () {
    test('不改写非本站 host 的 URL', () {
      // 一个已经指向别处的 URL 不能因为配了 CDN 就被"顺手"重定向。
      const foreign = 'https://evil.example.com/storage/v1/object/public/x';
      expect(_cfg('https://cdn.pocketworld.io').cdnRewrite(foreign), foreign);
    });

    test('输入不可解析时原样返回', () {
      const junk = 'not a url at all ::::';
      expect(_cfg('https://cdn.pocketworld.io').cdnRewrite(junk), junk);
    });

    test('CDN base 不可解析时不改写', () {
      expect(_cfg('%%%not-a-url%%%').cdnRewrite(_assetUrl), _assetUrl);
    });
  });

  group('isAcceptableCdn — 配置校验', () {
    test('http 被拒(降级攻击面)', () {
      expect(
        EndpointConfigResolver.isAcceptableCdn('http://cdn.supabase.co'),
        isFalse,
      );
    });

    test('白名单外的 host 被拒', () {
      expect(
        EndpointConfigResolver.isAcceptableCdn('https://cdn.evil.com'),
        isFalse,
      );
    });

    test('白名单内的 host 通过', () {
      // allowedHostSuffixes 目前含 '.supabase.co'
      expect(
        EndpointConfigResolver.isAcceptableCdn('https://x.supabase.co'),
        isTrue,
      );
    });

    test('空 host 被拒', () {
      expect(EndpointConfigResolver.isAcceptableCdn('https://'), isFalse);
    });
  });
}
