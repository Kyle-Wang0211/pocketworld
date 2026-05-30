// AnchorViewer — singleton holder for an "anchor" ThermionViewer
// that stays mounted for the lifetime of the community feed page.
//
// Why this exists: Thermion 0.3.4 ties every loaded asset to the
// loading viewer's `_assets` list (thermion_viewer_ffi.dart:526), and
// that list is destroyed in `viewer.dispose()` → `destroyAssets()`
// (line 552). Per-card viewers come and go as the user scrolls /
// navigates, so any asset they load dies with them — that's the
// "every page switch reloads the model" the user complained about.
//
// Fix: have ONE viewer that we never dispose, and load every shared
// asset through it. That viewer's `_assets` list never gets walked,
// so the assets persist for the whole session. Per-card viewers just
// `addToScene(cachedAsset)` — Filament cleanly supports the same
// asset being in multiple scenes simultaneously.
//
// The anchor's animationManager is what the asset is bound to. As long
// as the anchor lives, animations would work; for our static-scan
// use case animations are irrelevant either way.

import 'dart:async';

import 'package:thermion_flutter/thermion_flutter.dart';

class AnchorViewer {
  AnchorViewer._();

  static ThermionViewer? _viewer;
  static Completer<ThermionViewer> _ready = Completer<ThermionViewer>();

  /// Called by the anchor's ViewerWidget once createViewer resolves.
  /// Idempotent — second call (e.g. after a hot-restart) replaces.
  static void set(ThermionViewer v) {
    _viewer = v;
    if (!_ready.isCompleted) _ready.complete(v);
  }

  /// Resolves once the anchor viewer is ready. Used by the asset cache
  /// to gate loads on having an anchor to attach assets to.
  static Future<ThermionViewer> get future => _ready.future;

  /// Direct sync access — null until the anchor's onViewerAvailable
  /// has fired. Most callers should await [future] instead.
  static ThermionViewer? get current => _viewer;

  /// Tear-down hook for the host ViewerWidget's dispose. Without this
  /// the static `_viewer` keeps pointing at a freed Filament viewer
  /// after the host unmounts (e.g. when AuthGate swaps HomeScreen out
  /// on sign-out), and the next sign-in's LiveModelViews crash with
  /// `Engine_destroySwapChain: Object doesn't exist (double free?)`.
  /// Reset the completer too so the next anchor mount re-creates the
  /// gate from scratch instead of resolving instantly with the stale
  /// viewer.
  static void clear() {
    _viewer = null;
    _ready = Completer<ThermionViewer>();
  }
}
