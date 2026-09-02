/// 裁描述子的 native 绑定(pw_sqlite_descriptor_transform.cpp 内的
/// pw_sqlite_prune_descriptors_file / pw_sqlite_table_content_sha256)。
/// 仅 iOS(符号静态链接在 Runner);重活跑 Isolate.run。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _PruneC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Int32);
typedef _PruneD = int Function(Pointer<Utf8>, Pointer<Utf8>, int, int);
typedef _ResealC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _ResealD = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _XyC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _XyD = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _DigestC = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
);
typedef _DigestD = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
);

bool get databasePruneSupported => Platform.isIOS;

/// 复制 + 删 descriptors + (默认)裁 keypoints 仿射列 + VACUUM +
/// checkpoint + integrity_check;src 只读。0=成功。
Future<int> pruneDescriptorsFile(
  String source,
  String output, {
  bool stripKeypointAffine = true,
  bool dropRawMatches = false,
}) => Isolate.run(() {
  final lib = DynamicLibrary.process();
  final fn = lib.lookupFunction<_PruneC, _PruneD>(
    'pw_sqlite_prune_descriptors_file',
  );
  final s = source.toNativeUtf8();
  final o = output.toNativeUtf8();
  try {
    return fn(s, o, stripKeypointAffine ? 1 : 0, dropRawMatches ? 1 : 0);
  } finally {
    calloc.free(s);
    calloc.free(o);
  }
});

/// keypoints 的 x,y 等价摘要(忽略 cols 与仿射列)。裁仿射前后必须相同——
/// 这是"几何输入逐点未变"的判据。失败返回 null。
Future<String?> keypointsXySha256(String databasePath) => Isolate.run(() {
  final lib = DynamicLibrary.process();
  final fn = lib.lookupFunction<_XyC, _XyD>('pw_sqlite_keypoints_xy_sha256');
  final p = databasePath.toNativeUtf8();
  final out = calloc<Uint8>(65);
  try {
    if (fn(p, out.cast<Utf8>(), 65) != 0) return null;
    return out.cast<Utf8>().toDartString();
  } finally {
    calloc.free(p);
    calloc.free(out);
  }
});

/// 裁剪后按裁后 DB 内容重新盖章 ARKPOS1 侧车指纹。0=成功。
/// 不做这一步,核的 resume 身份校验会拒绝重建(实测 rc=5)。
Future<int> resealArkitPoseDigests(String databasePath, String sidecarPath) =>
    Isolate.run(() {
      final lib = DynamicLibrary.process();
      final fn = lib.lookupFunction<_ResealC, _ResealD>(
        'pw_sqlite_reseal_arkit_pose_digests',
      );
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
        'pw_sqlite_table_content_sha256',
      );
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
