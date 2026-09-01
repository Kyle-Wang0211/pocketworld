// Tiny URL → bytes cache for .glb files used by LiveModelView.
//
// Two-tier:
//   • In-memory map keyed by URL — survives within a session, shared
//     across cards so the same model viewed in feed + detail page is
//     downloaded once.
//   • Disk cache under getTemporaryDirectory()/glb_cache/<sha1>.glb —
//     survives app restarts. The OS may evict /tmp at will, which is
//     fine: next visit re-downloads.
//
// Thermion's loadGltfFromBuffer(Uint8List) takes raw bytes, sidestepping
// any "is this an asset path or a file path" ambiguity in loadGltf. So
// the cache returns Uint8List, not File.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../official_util/device_log.dart';

/// Hard ceiling on a single community download.
///
/// Set just above the `works` bucket's own 500 MB limit rather than at
/// some tidy small number, on purpose: B2B large-scene captures and future
/// mesh outputs have no established size bound yet, and the bucket cap was
/// deliberately left at 500 MB for that reason. A client cap below what the
/// server accepts would silently break legitimate uploads later. What this
/// value must do is bound the damage a hostile or corrupt asset can cause,
/// and it does — combined with streaming to disk, an oversized asset costs
/// bandwidth and a cancelled request, not an OOM.
const int kMaxDownloadBytes = 512 * 1024 * 1024;

/// Ceiling for assets that must be materialised as a `Uint8List`
/// (thermion's `loadGltfFromBuffer` takes bytes, not a path).
///
/// Much stricter than [kMaxDownloadBytes] because this one really does sit
/// in RAM. Today's sparse clouds are ~1.4 MB and the largest GLB sample in
/// use is ~17 MB, so 128 MB is generous while staying far from an OOM on
/// the oldest supported device. Assets above this are still usable through
/// [GlbCache.fetchPath], which never loads them into memory.
const int kMaxInMemoryBytes = 128 * 1024 * 1024;

class GlbCache {
  GlbCache._();
  static final GlbCache instance = GlbCache._();

  final Dio _dio = Dio(
    BaseOptions(
      responseType: ResponseType.bytes,
      connectTimeout: const Duration(seconds: 15),
      // 17MB+ GLBs (e.g. AntiqueCamera Khronos sample) need more than the
      // old 60s ceiling on slower mobile networks — a typical 2-3 Mbps
      // cellular link takes 50-70s alone, then add backoff/jitter and
      // we'd reliably time out. 180s gives comfortable headroom; the
      // user can still kill the request by scrolling away.
      receiveTimeout: const Duration(seconds: 180),
    ),
  );

  final Map<String, Uint8List> _mem = <String, Uint8List>{};
  final Map<String, Future<Uint8List>> _inflight =
      <String, Future<Uint8List>>{};

  /// De-dupes concurrent [fetchPath] downloads. Separate from [_inflight]
  /// because that one is keyed to in-memory byte futures.
  final Map<String, Future<String>> _inflightPaths = <String, Future<String>>{};

  Future<Uint8List> fetch(String url) {
    final cached = _mem[url];
    if (cached != null) return Future.value(cached);
    final pending = _inflight[url];
    if (pending != null) return pending;
    final future = _load(url);
    _inflight[url] = future;
    // `whenComplete` returns a NEW future that mirrors the original's
    // error — if we don't await/catch it, an _load() failure bubbles
    // up as an unhandled async error, runZonedGuarded's onError fires,
    // and main.dart's fallback runApp() kicks in (creating a fresh
    // mock-auth CurrentUser → state goes SignedOut → user ends up
    // staring at AuthRootView even though they were happily signed in).
    // `.ignore()` swallows the propagation on this secondary future
    // while the original `future` we return below still surfaces the
    // error to the caller's catch.
    future.whenComplete(() => _inflight.remove(url)).ignore();
    return future;
  }

  /// Variant of [fetch] that returns the on-disk path instead of the
  /// bytes. Required by the aether_cpp scene renderer path (cgltf
  /// uses fopen/fread inside `cgltf_parse_file`; it can't accept an
  /// HTTPS URL or an in-memory buffer through that entry point). The
  /// thermion path doesn't use this — it consumes the Uint8List
  /// directly via `loadGltfFromBuffer`.
  ///
  /// For `file://` URLs returns the local path immediately. For
  /// HTTPS URLs ensures bytes are downloaded + persisted to disk
  /// (re-using fetch's mem + disk caches) and returns the disk path.
  Future<String> fetchPath(String url) async {
    if (url.startsWith('file://')) {
      return Uri.parse(url).toFilePath();
    }
    final file = await _diskFile(url);
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    // Download straight to disk. This path deliberately does NOT go
    // through fetch(): cgltf wants a file, so materialising the bytes in
    // memory first would double peak memory for nothing — and it is what
    // made a large asset able to OOM the app before it was ever parsed.
    // It also means an asset between kMaxInMemoryBytes and
    // kMaxDownloadBytes is perfectly usable here.
    //
    // Downloads are de-duplicated per URL so two cards racing for the
    // same model don't fetch it twice.
    final pending = _inflightPaths[url];
    if (pending != null) return pending;
    final future = _downloadToFile(
      url,
      file,
      maxBytes: kMaxDownloadBytes,
    ).then((_) => file.path);
    _inflightPaths[url] = future;
    future.whenComplete(() => _inflightPaths.remove(url)).ignore();
    return future;
  }

  Future<Uint8List> _load(String url) async {
    // file:// — local artifact (downloaded by JobStatusWatcher into the
    // app docs dir). Read straight from disk; don't double-cache to
    // /tmp because the source IS the durable store.
    if (url.startsWith('file://')) {
      final path = Uri.parse(url).toFilePath();
      final f = File(path);
      if (!await f.exists()) {
        throw StateError('Local .glb missing at $path');
      }
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Empty local .glb at $path');
      }
      _mem[url] = bytes;
      return bytes;
    }
    final file = await _diskFile(url);
    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _mem[url] = bytes;
          return bytes;
        }
      } catch (_) {
        /* corrupt cache → fall through to redownload */
      }
    }
    // Stream to disk with a hard byte ceiling, then read back. Reasons:
    //
    //  1. DoS: a community work is downloaded AUTOMATICALLY when its card
    //     scrolls into the feed. Before this, any publisher could upload a
    //     huge (or malformed) file and OOM every viewer who scrolled past
    //     it. The bucket-level size cap that would have been the cheapest
    //     first gate was deliberately NOT lowered — B2B large-scene and
    //     future mesh outputs have no known size bound yet — so the
    //     client-side guard is the ONLY defence and has to be real.
    //
    //  2. Memory: the old path built the whole body in memory and then
    //     wrote a second copy to disk, peaking at ~2x file size. Streaming
    //     to disk first drops the download peak to one chunk.
    //
    // Note: Dio has no `maxContentLength` (that is an axios concept) — the
    // only real guard is counting bytes as they arrive and cancelling.
    // The Content-Length precheck below is a bandwidth optimisation, not a
    // security boundary: it is absent under chunked encoding and a hostile
    // server can simply lie.
    await _downloadToFile(url, file, maxBytes: kMaxDownloadBytes);

    final size = await file.length();
    if (size == 0) {
      await _safeDelete(file);
      throw StateError('Empty .glb response for $url');
    }
    // Only now does anything enter memory. fetchPath() callers (cgltf,
    // which needs a real file) never reach this line.
    if (size > kMaxInMemoryBytes) {
      throw StateError(
        'Asset too large to load in memory: $size bytes '
        '(limit $kMaxInMemoryBytes). Use fetchPath() for a disk-backed load.',
      );
    }
    final bytes = await file.readAsBytes();
    _mem[url] = bytes;
    return bytes;
  }

  /// Streams [url] into [dest], aborting if more than [maxBytes] arrive.
  /// Writes to a `.part` file and renames on success so a cancelled or
  /// failed download can never be mistaken for a valid cache entry.
  Future<void> _downloadToFile(
    String url,
    File dest, {
    required int maxBytes,
  }) async {
    await dest.parent.create(recursive: true);
    final part = File('${dest.path}.part');
    final cancelToken = CancelToken();
    IOSink? sink;
    var received = 0;
    var exceeded = false;
    try {
      final res = await _dio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );
      final declared = int.tryParse(
        res.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declared != null && declared > maxBytes) {
        exceeded = true;
        cancelToken.cancel('declared size $declared exceeds $maxBytes');
        throw StateError(
          'Asset declares $declared bytes, over the $maxBytes limit: $url',
        );
      }

      sink = part.openWrite();
      await for (final chunk in res.data!.stream) {
        received += chunk.length;
        if (received > maxBytes) {
          exceeded = true;
          // Stop pulling bytes immediately; do not wait for the body to
          // finish just to reject it afterwards.
          cancelToken.cancel('received $received exceeds $maxBytes');
          throw StateError(
            'Asset exceeded the $maxBytes byte limit while downloading: $url',
          );
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await dest.exists()) await _safeDelete(dest);
      await part.rename(dest.path);
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          /* already broken */
        }
      }
      await _safeDelete(part);
      if (exceeded) {
        DeviceLog.log('GlbCache', '拒绝超限资源($received/$maxBytes bytes): $url');
      }
      rethrow;
    }
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      /* best-effort */
    }
  }

  Future<File> _diskFile(String url) async {
    final dir = await getTemporaryDirectory();
    final hash = sha1.convert(utf8.encode(url)).toString();
    // Preserve the source URL's extension so the native loader sees a
    // sensible file name. Originally this hardcoded `.glb` (when the
    // cache only held GLB), but Phase 6.4f routes PLY/SPZ through here
    // too. The native spz parser uses extension as a hint for which
    // decoder to invoke when both PLY and SPZ are accepted, and the
    // log line `load_spz: parse/decode failed status=-1 path='...glb'`
    // is exactly that hint going wrong.
    final ext = _extensionForUrl(url);
    return File('${dir.path}/glb_cache/$hash$ext');
  }

  /// Extract the file extension (e.g. `.spz`, `.ply`, `.glb`) from a
  /// URL, stripping any query string / fragment. Falls back to `.glb`
  /// for legacy compatibility with the cache's original purpose.
  String _extensionForUrl(String url) {
    final lower = url.toLowerCase();
    final qIdx = lower.indexOf('?');
    final hashIdx = lower.indexOf('#');
    final cut = [
      qIdx,
      hashIdx,
    ].where((i) => i >= 0).fold<int>(lower.length, (a, b) => a < b ? a : b);
    final path = lower.substring(0, cut);
    for (final ext in const ['.spz', '.ply', '.gltf', '.splat', '.glb']) {
      if (path.endsWith(ext)) return ext;
    }
    return '.glb';
  }

  // _persist() was removed with the streaming rewrite: downloads now land
  // on disk directly (via a .part file + rename), so there is no longer a
  // separate "write the in-memory copy out" step, and no window where
  // fetch() has bytes that fetchPath() can't find on disk.
}
