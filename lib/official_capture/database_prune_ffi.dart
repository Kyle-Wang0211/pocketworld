/// 裁描述子的 native 绑定(pw_sqlite_descriptor_transform.cpp 内的
/// pw_sqlite_prune_descriptors_file / pw_sqlite_table_content_sha256)。
/// 仅 iOS(符号静态链接在 Runner);重活跑 Isolate.run。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _PruneC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PruneD = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _DigestC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _DigestD = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);

bool get databasePruneSupported => Platform.isIOS;

/// 复制+删 descriptors+VACUUM+integrity_check;src 只读。0=成功。
Future<int> pruneDescriptorsFile(String source, String output) =>
    Isolate.run(() {
      final lib = DynamicLibrary.process();
      final fn = lib.lookupFunction<_PruneC, _PruneD>(
          'pw_sqlite_prune_descriptors_file');
      final s = source.toNativeUtf8();
      final o = output.toNativeUtf8();
      try {
        return fn(s, o);
      } finally {
        calloc.free(s);
        calloc.free(o);
      }
    });

/// 裁剪后按裁后 DB 内容重新盖章 ARKPOS1 侧车指纹。0=成功。
/// 不做这一步,核的 resume 身份校验会拒绝重建(实测 rc=5)。
Future<int> resealArkitPoseDigests(String databasePath, String sidecarPath) =>
    Isolate.run(() {
      final lib = DynamicLibrary.process();
      final fn = lib.lookupFunction<_PruneC, _PruneD>(
          'pw_sqlite_reseal_arkit_pose_digests');
      final d = databasePath.toNativeUtf8();
      final s = sidecarPath.toNativeUtf8();
      try {
        return fn(d, s);
      } finally {
        calloc.free(d);
        calloc.free(s);
      }
    });

/// 单表内容 SHA-256(rowid 序,列带类型标记)。失败返回 null。
Future<String?> tableContentSha256(String databasePath, String table) =>
    Isolate.run(() {
      final lib = DynamicLibrary.process();
      final fn = lib.lookupFunction<_DigestC, _DigestD>(
          'pw_sqlite_table_content_sha256');
      final p = databasePath.toNativeUtf8();
      final t = table.toNativeUtf8();
      final out = calloc<Uint8>(65);
      try {
        final rc = fn(p, t, out.cast<Utf8>(), 65);
        if (rc != 0) return null;
        return out.cast<Utf8>().toDartString();
      } finally {
        calloc.free(p);
        calloc.free(t);
        calloc.free(out);
      }
    });
