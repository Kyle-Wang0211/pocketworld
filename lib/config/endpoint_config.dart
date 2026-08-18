// EndpointConfig — resolves the backend URL / anon key at RUNTIME instead
// of baking them into the binary.
//
// Why this exists (2026-08-16):
//   `main.dart` used to read SUPABASE_URL / SUPABASE_ANON_KEY through
//   `String.fromEnvironment` with hardcoded defaults. On this project
//   `--dart-define` does NOT reach the iOS xcconfig chain (verified on
//   device 2026-08-09, see docs/runbooks/app-update-install-runbook.md),
//   so those defaults ARE the shipped values — the backend address is
//   effectively compiled into the binary.
//
//   That makes a backend/domain move a "ship a new build" event: every
//   copy of the app already on a user's phone keeps pointing at the old
//   host, and we cannot force anyone to upgrade. Resolving at runtime
//   downgrades that from "cut a release and wait for adoption" to
//   "edit a JSON file".
//
// Resolution order (first usable wins):
//   1. Fresh cache        — used immediately, refreshed in the background.
//   2. Remote config      — fetched when the cache is missing or stale.
//   3. Stale cache        — remote unreachable, but we had something.
//   4. Built-in constants — first launch, offline. Always present, so the
//                           app can never fail to start because of this.
//
// Startup cost: zero when the cache is fresh (the refresh is detached).
// Only a cold first launch (or a >`staleAfter` gap) waits, and that wait
// is capped by `coldTimeout`.
//
// SECURITY: the config endpoint decides where the app sends credentials,
// so a hijacked endpoint would be a credential-redirect vector. Fetched
// values are therefore validated before use — https only, and the host
// must match `allowedHostSuffixes`. Anything else is discarded and the
// previous value stands.
//
// NOTE: with `configEndpoints` empty (the default until a long-lived
// domain exists) this class is a behavioural no-op — it resolves to the
// same built-in constants the old inline code used.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../aether_prefs.dart';

enum EndpointConfigSource { builtin, cache, remote }

@immutable
class EndpointConfig {
  final String supabaseUrl;
  final String supabaseAnonKey;
  final EndpointConfigSource source;

  /// Origin that public storage assets are served from, e.g.
  /// `https://cdn.example.com`. NULL = serve straight from `supabaseUrl`,
  /// which is exactly today's behaviour.
  ///
  /// Why this is a config value and not a constant: the edge layer is the
  /// ONE part of the defense stack that cannot be shared between the
  /// overseas and mainland-China deployments — ICP filing requires
  /// mainland servers + a filed domain, so the two deployments must use
  /// different CDN vendors (Cloudflare vs Aliyun/Tencent). Everything
  /// else in the defense stack is portable Postgres/Dart. Keeping the
  /// asset origin in config is the seam that lets one codebase serve
  /// both — swapping the edge vendor must never mean editing code, let
  /// alone shipping a build.
  ///
  /// Only the ORIGIN is swapped; the `/storage/v1/object/public/...`
  /// path is preserved, because a CDN in front of Supabase Storage
  /// reverse-proxies the same paths.
  final String? assetCdnBase;

  const EndpointConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.source,
    this.assetCdnBase,
  });

  /// Rewrite a Supabase-issued public storage URL to go through the CDN.
  /// Returns [url] untouched when no CDN is configured, when the input is
  /// unparseable, or when it does not point at our own Supabase host —
  /// this must never be able to redirect a URL somewhere new.
  String cdnRewrite(String url) {
    final base = assetCdnBase;
    if (base == null || base.isEmpty) return url;
    final src = Uri.tryParse(url);
    final cdn = Uri.tryParse(base);
    if (src == null || cdn == null || cdn.host.isEmpty) return url;
    final origin = Uri.tryParse(supabaseUrl);
    if (origin == null || src.host != origin.host) return url;
    return src.replace(scheme: cdn.scheme, host: cdn.host, port: cdn.port).toString();
  }

  @override
  String toString() =>
      'EndpointConfig(${Uri.tryParse(supabaseUrl)?.host ?? supabaseUrl}, '
      'cdn: ${assetCdnBase == null ? 'none' : Uri.tryParse(assetCdnBase!)?.host ?? assetCdnBase}, '
      'source: ${source.name})';
}

class EndpointConfigResolver {
  EndpointConfigResolver._();

  // ── Built-in fallback ───────────────────────────────────────────────
  // Kept as `String.fromEnvironment` so a working --dart-define setup
  // (host tools, tests, a future build-system fix) can still override.
  static const String builtinUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://tzvwkqmgaourwqrmxbyb.supabase.co',
  );
  static const String builtinAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_ur4tTV2iXSV4NsL3YYttyw_SIjFAMST',
  );

  /// Config endpoints, tried in order. Each must return the JSON shape
  /// `{"supabase_url": "...", "supabase_anon_key": "...",
  ///   "asset_cdn_base": "https://cdn.example.com"}`
  /// (`asset_cdn_base` optional — omit it to serve assets from Supabase).
  ///
  /// Point these at a host we commit to never renaming — it is the one
  /// address that cannot be moved by this mechanism. Serving a few
  /// hundred bytes of static JSON, so any cheap origin works.
  ///
  /// EMPTY = feature dormant, built-in constants are used. Fill this in
  /// once a long-lived domain is registered.
  static const List<String> configEndpoints = <String>[
    // 'https://cfg.<long-lived-domain>/app/endpoints.json',
  ];

  /// A fetched `supabase_url` is only honoured when its host ends with
  /// one of these. Prevents a compromised/spoofed config response from
  /// pointing the app (and its auth tokens) at an attacker's host.
  static const List<String> allowedHostSuffixes = <String>[
    '.supabase.co',
    // '.aether3d.cn',        ← add alongside the production domain
  ];

  static const Duration defaultColdTimeout = Duration(milliseconds: 2500);
  static const Duration defaultStaleAfter = Duration(hours: 24);

  static const String _kUrl = 'endpoint_config.supabase_url';
  static const String _kKey = 'endpoint_config.supabase_anon_key';
  static const String _kAt = 'endpoint_config.fetched_at_ms';
  static const String _kCdn = 'endpoint_config.asset_cdn_base';

  /// The config the app actually booted with. Set once by [resolve] so
  /// consumers that are constructed later (services, widgets) can read the
  /// asset origin without threading it through every constructor.
  ///
  /// Read-mostly and deliberately not reactive: a background refresh may
  /// replace it, but callers resolve the origin per URL, so the next URL
  /// built simply uses the newer value. Nothing caches a rewritten URL.
  static EndpointConfig? current;

  static const EndpointConfig _builtin = EndpointConfig(
    supabaseUrl: builtinUrl,
    supabaseAnonKey: builtinAnonKey,
    source: EndpointConfigSource.builtin,
  );

  /// Resolve the endpoint to boot with. Never throws and never returns
  /// null — the built-in constants are the floor.
  ///
  /// [nowMs] and [client] are injection seams for tests.
  static Future<EndpointConfig> resolve({
    Duration coldTimeout = defaultColdTimeout,
    Duration staleAfter = defaultStaleAfter,
    int? nowMs,
    Dio? client,
  }) async {
    // Single funnel so [current] is set on every path — _resolveInner has
    // four returns, and wiring each one individually is how one quietly
    // gets missed.
    final cfg = await _resolveInner(
      coldTimeout: coldTimeout,
      staleAfter: staleAfter,
      nowMs: nowMs,
      client: client,
    );
    current = cfg;
    return cfg;
  }

  static Future<EndpointConfig> _resolveInner({
    Duration coldTimeout = defaultColdTimeout,
    Duration staleAfter = defaultStaleAfter,
    int? nowMs,
    Dio? client,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;

    EndpointConfig? cached;
    int? fetchedAt;
    try {
      final prefs = await AetherPrefs.getInstance();
      final url = await prefs.getString(_kUrl);
      final key = await prefs.getString(_kKey);
      final cdn = await prefs.getString(_kCdn);
      fetchedAt = await prefs.getInt(_kAt);
      if (url != null && key != null && _isAcceptable(url, key)) {
        cached = EndpointConfig(
          supabaseUrl: url,
          supabaseAnonKey: key,
          // A cached CDN base is re-validated on read, not trusted because
          // it was trusted once — the allowlist may have tightened since.
          assetCdnBase: (cdn != null && _isAcceptableCdn(cdn)) ? cdn : null,
          source: EndpointConfigSource.cache,
        );
      }
    } catch (_) {
      // Prefs unavailable (very early launch, test harness). Fall through.
    }

    if (configEndpoints.isEmpty) {
      return cached ?? _builtin;
    }

    final isFresh =
        cached != null &&
        fetchedAt != null &&
        now - fetchedAt < staleAfter.inMilliseconds;

    if (isFresh) {
      // Serve the cache now; pull a newer one for the *next* launch.
      unawaited(_refresh(client: client, nowMs: now));
      return cached;
    }

    // Cache missing or stale — it is worth a bounded wait so a moved
    // backend is picked up on this launch rather than the next one.
    final remote = await _fetch(client: client)
        .timeout(coldTimeout, onTimeout: () => null)
        .catchError((_) => null);

    if (remote != null) {
      unawaited(_persist(remote, now));
      return remote;
    }
    return cached ?? _builtin;
  }

  static Future<void> _refresh({Dio? client, required int nowMs}) async {
    try {
      final remote = await _fetch(client: client);
      if (remote != null) await _persist(remote, nowMs);
    } catch (_) {
      // Background refresh is best effort.
    }
  }

  /// Try each endpoint in order; first valid response wins.
  static Future<EndpointConfig?> _fetch({Dio? client}) async {
    final dio =
        client ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
            responseType: ResponseType.plain,
          ),
        );
    for (final endpoint in configEndpoints) {
      try {
        final res = await dio.get<String>(endpoint);
        final body = res.data;
        if (body == null || body.isEmpty) continue;
        final decoded = jsonDecode(body);
        if (decoded is! Map) continue;
        final url = decoded['supabase_url'];
        final key = decoded['supabase_anon_key'];
        if (url is! String || key is! String) continue;
        if (!_isAcceptable(url, key)) {
          debugPrint(
            '[EndpointConfig] rejected $endpoint — host/scheme not allowed',
          );
          continue;
        }
        // A bad/omitted CDN base degrades to serving from Supabase
        // directly — it must never block the endpoint from resolving,
        // because a rejected CDN would otherwise take the whole app down
        // with it.
        final rawCdn = decoded['asset_cdn_base'];
        String? cdn;
        if (rawCdn is String && rawCdn.isNotEmpty) {
          if (_isAcceptableCdn(rawCdn)) {
            cdn = rawCdn;
          } else {
            debugPrint(
              '[EndpointConfig] rejected asset_cdn_base from $endpoint — '
              'host/scheme not allowed; serving assets from Supabase',
            );
          }
        }
        return EndpointConfig(
          supabaseUrl: url,
          supabaseAnonKey: key,
          assetCdnBase: cdn,
          source: EndpointConfigSource.remote,
        );
      } catch (_) {
        // Try the next endpoint.
      }
    }
    return null;
  }

  static Future<void> _persist(EndpointConfig cfg, int nowMs) async {
    try {
      final prefs = await AetherPrefs.getInstance();
      await prefs.setString(_kUrl, cfg.supabaseUrl);
      await prefs.setString(_kKey, cfg.supabaseAnonKey);
      await prefs.setInt(_kAt, nowMs);
      final cdn = cfg.assetCdnBase;
      if (cdn != null && cdn.isNotEmpty) {
        await prefs.setString(_kCdn, cdn);
      } else {
        await prefs.remove(_kCdn);
      }
    } catch (_) {
      // Cache write failure only costs us a refetch next launch.
    }
  }

  /// https + allow-listed host + non-empty key. Deliberately strict:
  /// a value that fails this is discarded, not "best effort" accepted.
  @visibleForTesting
  static bool isAcceptable(String url, String key) => _isAcceptable(url, key);

  @visibleForTesting
  static bool isAcceptableCdn(String base) => _isAcceptableCdn(base);

  /// A CDN base must clear the same bar as the API host: https, and a host
  /// inside the allowlist. It fronts model/thumbnail bytes the app renders,
  /// so pointing it at an attacker's origin is a content-substitution
  /// vector — same class of risk as redirecting the API, and validated the
  /// same way rather than trusted because "it's only images".
  static bool _isAcceptableCdn(String base) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    if (allowedHostSuffixes.isEmpty) return false;
    for (final suffix in allowedHostSuffixes) {
      if (uri.host.endsWith(suffix)) return true;
    }
    return false;
  }

  static bool _isAcceptable(String url, String key) {
    if (key.trim().isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    if (allowedHostSuffixes.isEmpty) return false;
    for (final suffix in allowedHostSuffixes) {
      if (uri.host.endsWith(suffix)) return true;
    }
    return false;
  }

  /// Test/support seam — drops the cached endpoint so the next resolve
  /// starts from scratch.
  static Future<void> clearCache() async {
    try {
      final prefs = await AetherPrefs.getInstance();
      await prefs.remove(_kUrl);
      await prefs.remove(_kKey);
      await prefs.remove(_kAt);
      await prefs.remove(_kCdn);
    } catch (_) {}
  }
}
