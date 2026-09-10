// sqlite_db_health.dart — 「这个 sqlite 文件还能开吗」的**结构性**判据(纯函数)。
//
// [2026-09-08 实机定罪] 拍摄被杀(闪退 / jetsam / 用户划掉)时,流式核写进
// sqlite 的东西还压在一个没提交的长事务里,进程一死就只剩一个残骸。而
// DatabaseArchiveResolver.isRecoverable 只回答"db 文件在不在",不回答"能不能
// 开" —— 于是「开始训练」和「补拍」都一路走到 native 才炸成 errDb,用户看到
// 的是一个红弹窗,不是一句人话。
//
// 判据不是"文件太小"这种拍脑袋的阈值,而是 db 自己的头字段互相矛盾。真机
// cap_1788845271610360 的残骸 vs 本机重建出的健康库,逐字段对拍:
//
//                        残骸(被杀)        健康(跑完 finalize)
//   magic                ok                 ok
//   page_size            4096               4096
//   header page_count    3025               6252
//   实际文件页数          1  (4096 字节)      6252 (25608192 字节)
//   sqlite3 .tables      malformed          11 张表
//
// 头里写着 3025 页、文件里只有 1 页 —— 后面 3024 页在被杀那一刻还没落盘。
// 这正是 sqlite 报 "database disk image is malformed" 的原因,也正是这条
// 判据要抓的东西:**头声称的页数 > 文件实际能提供的页数 ⇒ 被截断 ⇒ 开不了**。
//
// 字段偏移与"何时可信"的规则出自 SQLite 官方 file-format 文档
// (https://sqlite.org/fileformat2.html §1.3 The Database Header):
//   offset 0   16 字节  header string "SQLite format 3\0"
//   offset 16   2 字节  page size(1 表示 65536)
//   offset 24   4 字节  file change counter
//   offset 28   4 字节  size of the database file in pages("in-header size")
//   offset 92   4 字节  version-valid-for number
// 文档明写:in-header size 只有在**非零**且 change counter == version-valid-for
// 时才有效;否则应改用"文件字节数 ÷ 页大小"。所以下面在头不可信时**判为可用**
// (让 native 去下结论),不拿一个不可信的字段去毙掉用户的数据 —— 误判成
// "坏了"会把一个本来能续跑的项目推去重跑,代价比多走一次 native 大得多。

import 'dart:io';
import 'dart:typed_data';

/// [sqliteDatabaseUsable] 的判定结果 —— 带原因,便于落日志/给用户看。
class SqliteDbHealth {
  const SqliteDbHealth._(this.usable, this.reason);

  /// 能开(或"看不出不能开",交给 native 定夺)。
  const SqliteDbHealth.usable() : this._(true, null);

  /// 开不了,[reason] 说明是哪一条不成立。
  const SqliteDbHealth.broken(String reason) : this._(false, reason);

  final bool usable;

  /// usable 时为 null。
  final String? reason;
}

const int _kHeaderBytes = 100;

/// 判断 [file] 是不是一个还能打开的 sqlite 数据库。
///
/// 只读前 100 字节 + 一次 stat,不解析 b-tree、不引 sqlite 依赖 —— 这条判据
/// 会在长按菜单弹出前跑,不能有可感知的耗时。
///
/// **诚实降级**:任何"读不出/看不懂"的情况一律返回 usable,让 native 去下
/// 结论。这条判据的职责是**认出那个已被定罪的残骸形态**,不是替 sqlite 做
/// 全面体检;把它写成"存疑即毙"会误伤真正能续跑的项目。
SqliteDbHealth sqliteDatabaseUsable(File file) {
  int length;
  Uint8List head;
  try {
    length = file.lengthSync();
    if (length == 0) return const SqliteDbHealth.broken('db 是空文件(0 字节)');
    if (length < _kHeaderBytes) {
      return SqliteDbHealth.broken('db 只有 $length 字节,连 100 字节的头都不够');
    }
    final raf = file.openSync();
    try {
      head = raf.readSync(_kHeaderBytes);
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    // 读不出来 ≠ 坏了(可能是权限/正被占用)。交给 native。
    return const SqliteDbHealth.usable();
  } catch (_) {
    return const SqliteDbHealth.usable();
  }
  if (head.length < _kHeaderBytes) return const SqliteDbHealth.usable();
  return sqliteHeaderUsable(head, fileLength: length);
}

/// [sqliteDatabaseUsable] 的纯内核:只吃头 100 字节 + 文件长度。
///
/// 拆出来是为了能在纯 VM 里拿**真机字节**穷举断言(见
/// test/sqlite_db_health_test.dart),不需要造真文件。
SqliteDbHealth sqliteHeaderUsable(Uint8List head, {required int fileLength}) {
  if (head.length < _kHeaderBytes) return const SqliteDbHealth.usable();

  const magic = <int>[
    0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite f"
    0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00, // "ormat 3\0"
  ];
  for (var i = 0; i < magic.length; i++) {
    if (head[i] != magic[i]) {
      return const SqliteDbHealth.broken('不是 sqlite 文件(头 16 字节不对)');
    }
  }

  final data = ByteData.sublistView(head);
  // page size:官方规定是 512..32768 的 2 的幂,或用 1 表示 65536。
  var pageSize = data.getUint16(16);
  if (pageSize == 1) pageSize = 65536;
  if (pageSize < 512 || (pageSize & (pageSize - 1)) != 0) {
    return SqliteDbHealth.broken('页大小非法($pageSize)');
  }

  final changeCounter = data.getUint32(24);
  final headerPages = data.getUint32(28);
  final versionValidFor = data.getUint32(92);
  // 官方规则:in-header size 非零且 change counter == version-valid-for 才可信。
  final headerSizeTrustworthy =
      headerPages != 0 && changeCounter == versionValidFor;
  if (!headerSizeTrustworthy) return const SqliteDbHealth.usable();

  final filePages = fileLength ~/ pageSize;
  if (headerPages > filePages) {
    // 就是这一条抓住了真机残骸:头说 3025 页,文件只有 1 页。
    return SqliteDbHealth.broken(
      'db 被截断:头声称 $headerPages 页,文件只有 $filePages 页'
      '($fileLength 字节 / $pageSize)',
    );
  }
  return const SqliteDbHealth.usable();
}
