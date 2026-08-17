// C7 的防线验证:社区资源下载必须有真实的字节上限。
//
// 为什么用真的 HttpServer 而不是 mock Dio:要验的正是"边收边数、超限就取消"
// 这个流式行为本身。mock 掉 Dio 就把被测逻辑一起 mock 掉了 —— 那样即使
// 上限判断写错也测不出来。
//
// 背景:社区卡片滚进 feed 会**自动**下载模型。在此之前任何发布者上传一个
// 超大文件就能 OOM 每个滑过它的人。而桶级尺寸上限被有意保留在 500MB
// (B端大场景与 mesh 产物体积上限未知),所以客户端守卫是唯一防线。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pocketworld_flutter/community/glb_cache.dart';

/// 把缓存目录指到临时目录,避免测试碰真实 app 目录。
class _TmpPathProvider extends PathProviderPlatform {
  _TmpPathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  late Directory tmp;
  late HttpServer server;
  late String base;

  /// 服务端按 URL 里的 size 参数吐指定字节数。
  /// `?nolen=1` 时不发 Content-Length(模拟 chunked / 服务端撒谎),
  /// 用来证明真正的守卫是逐块计数而不是那个预检。
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('glb_cache_guard');
    PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.address}:${server.port}';
    server.listen((req) async {
      final size = int.parse(req.uri.queryParameters['size'] ?? '0');
      final hideLen = req.uri.queryParameters['nolen'] == '1';
      if (!hideLen) req.response.headers.contentLength = size;
      req.response.headers.contentType = ContentType.binary;
      // 分块发,让客户端有机会在中途中止。
      const chunk = 64 * 1024;
      var sent = 0;
      while (sent < size) {
        final n = (size - sent) < chunk ? (size - sent) : chunk;
        req.response.add(List<int>.filled(n, 0x41));
        // flush 让字节真的上路,而不是全攒在缓冲里一次性发完。
        await req.response.flush();
        sent += n;
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('正常大小的资源可以下载,且落盘', () async {
    final url = '$base/ok.ply?size=${256 * 1024}';
    final path = await GlbCache.instance.fetchPath(url);
    final f = File(path);
    expect(await f.exists(), isTrue);
    expect(await f.length(), 256 * 1024);
  });

  test('声明的 Content-Length 超过硬顶 → 拒绝,且不留残file', () async {
    // 声明 600MB(> kMaxDownloadBytes 512MB)。服务端其实只会吐这么多字节,
    // 但客户端应当在预检阶段就拒绝,连身体都不收。
    final url = '$base/huge.ply?size=${600 * 1024 * 1024}';
    await expectLater(
      GlbCache.instance.fetchPath(url),
      throwsA(isA<StateError>()),
    );
    // .part 不能留下,否则下次会被误当成有效缓存。
    final leftovers = await Directory('${tmp.path}/glb_cache')
        .list()
        .where((e) => e.path.endsWith('.part'))
        .toList()
        .catchError((_) => <FileSystemEntity>[]);
    expect(leftovers, isEmpty, reason: '超限下载不得留下 .part 残file');
  });

  test('🔑 服务端不发 Content-Length 时,仍靠逐块计数拦住(预检不是安全边界)',
      () async {
    // 这条是 C7 的核心:chunked 编码下没有 Content-Length,恶意服务端也可以
    // 直接撒谎。所以必须靠边收边数。
    // 用 fetch()(走 kMaxInMemoryBytes=128MB 这条更严的线),否则要真发 512MB。
    final url = '$base/lie.ply?size=${140 * 1024 * 1024}&nolen=1';
    await expectLater(
      GlbCache.instance.fetch(url),
      throwsA(isA<StateError>()),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('超过内存上限但低于下载上限的资源,fetchPath 仍可用', () async {
    // fetchPath 从不把资源读进内存,所以这个区间必须是可用的 ——
    // 将来 B 端大场景/mesh 产物正落在这里。
    // 取 130MB:> kMaxInMemoryBytes(128MB) 且 < kMaxDownloadBytes(512MB)。
    final url = '$base/big.ply?size=${130 * 1024 * 1024}';
    final path = await GlbCache.instance.fetchPath(url);
    expect(await File(path).length(), 130 * 1024 * 1024);

    // 同一个资源走 fetch() 应当被内存上限挡下,而不是 OOM。
    await expectLater(
      GlbCache.instance.fetch('$base/big2.ply?size=${130 * 1024 * 1024}'),
      throwsA(isA<StateError>()),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
