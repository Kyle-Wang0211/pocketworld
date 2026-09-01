// C8 的关键验证:迁移写错 = 把已登录用户登出。
//
// 两个最容易致错的点,分别对应上游文档里的两个坑:
//   1. key 必须是 sb-<ref>-auth-token。包 README 的示例用的是
//      supabasePersistSessionKey,而包源码自己注释那个常量"实际未在使用"
//      —— 照抄示例会读不到旧 session,静默登出所有人。
//   2. 迁移必须先写新、后删旧。反过来一旦中途失败,两处都没有 session。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocketworld_flutter/auth/secure_session_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'https://tzvwkqmgaourwqrmxbyb.supabase.co';
  const expectedKey = 'sb-tzvwkqmgaourwqrmxbyb-auth-token';
  const fakeSession = '{"access_token":"a","refresh_token":"r"}';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('🔑 key 推导必须与 supabase_flutter 的默认值逐字一致', () {
    // 若这条断言失败,说明 key 规则漂了 —— 后果是所有已登录用户升级后被登出。
    expect(supabaseSessionKeyFor(url), expectedKey);
  });

  test('key 只取 host 的第一段(不含 .supabase.co)', () {
    expect(supabaseSessionKeyFor('https://abcdefgh.supabase.co'),
        'sb-abcdefgh-auth-token');
  });

  test('迁移:明文 SharedPreferences 里的 session 被搬进安全存储,且旧值清掉',
      () async {
    SharedPreferences.setMockInitialValues({expectedKey: fakeSession});

    final storage = SecureSessionStorage(supabaseUrl: url);
    await storage.initialize();

    // 新存储拿得到 —— 这就是"用户不会被登出"。
    expect(await storage.accessToken(), fakeSession);
    expect(await storage.hasAccessToken(), isTrue);

    // 旧的明文值必须已被清除,否则令牌仍留在会进备份的地方。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(expectedKey), isNull,
        reason: '迁移后明文副本必须删除,否则等于没修');
  });

  test('迁移是幂等的:安全存储已有值时不覆盖、也不再读明文', () async {
    const newer = '{"access_token":"NEWER"}';
    FlutterSecureStorage.setMockInitialValues({expectedKey: newer});
    SharedPreferences.setMockInitialValues({expectedKey: fakeSession});

    final storage = SecureSessionStorage(supabaseUrl: url);
    await storage.initialize();

    // 不能被旧的明文值覆盖 —— 那会把用户退回到一个更旧的 session。
    expect(await storage.accessToken(), newer);
  });

  test('没有旧值时迁移安静跳过,不误建空条目', () async {
    final storage = SecureSessionStorage(supabaseUrl: url);
    await storage.initialize();
    expect(await storage.hasAccessToken(), isFalse);
    expect(await storage.accessToken(), isNull);
  });

  test('persist / remove 走的是同一个 key(否则读写会错位)', () async {
    final storage = SecureSessionStorage(supabaseUrl: url);
    await storage.initialize();

    await storage.persistSession(fakeSession);
    expect(await storage.accessToken(), fakeSession);

    await storage.removePersistedSession();
    expect(await storage.hasAccessToken(), isFalse);
  });
}
