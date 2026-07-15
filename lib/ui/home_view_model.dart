// HomeViewModel — surfaces the user's scan records to the gallery.
//
// Backed by ScanRecordStore (JSON file under app docs). The ViewModel
// adds in front of the persisted records a small set of bundled SAMPLE
// records (so a fresh install isn't an empty gallery; tapping a sample
// shows a real GLB rendered through LiveModelView). Once the user has
// uploaded their first scan and it's finished, real records appear at
// the top of the list (sorted newest-first by createdAt).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../me/scan_record_store.dart';
import 'scan_record.dart';

class HomeViewModel extends ChangeNotifier {
  HomeViewModel({ScanRecordStore? store})
    : _store = store ?? ScanRecordStore.instance;

  final ScanRecordStore _store;
  StreamSubscription<List<ScanRecord>>? _sub;
  List<ScanRecord> _userRecords = const [];
  bool _loading = false;

  /// Combined view: the user's persisted records (newest first) followed
  /// by bundled sample records so brand-new accounts aren't empty.
  List<ScanRecord> get scanRecords => [..._userRecords, ..._sampleSeed];
  bool get isLoading => _loading;

  /// Left / right columns in the waterfall gallery. Even indices go
  /// left, odd go right — mirrors HomePage.swift's leftColumnRecords /
  /// rightColumnRecords partition.
  List<ScanRecord> get leftColumnRecords {
    final all = scanRecords;
    return [
      for (int i = 0; i < all.length; i++)
        if (i.isEven) all[i],
    ];
  }

  List<ScanRecord> get rightColumnRecords {
    final all = scanRecords;
    return [
      for (int i = 0; i < all.length; i++)
        if (i.isOdd) all[i],
    ];
  }

  /// Uniform thumbnail height for the personal vault. Switched from the
  /// original "curated waterfall" (variable heights per index) to a
  /// regular symmetric grid where the left and right columns end at
  /// the same Y, per user feedback. 240 px keeps the same vertical
  /// rhythm as the average of the old pattern.
  static const double _vaultThumbHeight = 240;

  double imageHeightFor({required int positionInColumn, required bool isLeft}) {
    return _vaultThumbHeight;
  }

  Future<void> loadRecords() async {
    _loading = true;
    notifyListeners();
    await _store.ensureLoaded();
    _userRecords = _store.records;
    _sub ??= _store.changes.listen((next) {
      _userRecords = next;
      notifyListeners();
    });
    _loading = false;
    notifyListeners();
  }

  /// Delete a record (user-owned only). Sample records are read-only.
  Future<void> deleteRecord(ScanRecord record) async {
    if (_isSample(record)) return;
    await _store.delete(record.id);
  }

  bool _isSample(ScanRecord record) =>
      _sampleSeed.any((s) => s.id == record.id);

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  /// Sample card IDs that resolve to bundled GLB assets shipped with the
  /// app. Tapping these ID-prefixed records routes to LiveModelView with
  /// the corresponding GLB pre-loaded.
  static const String sampleHelmetId = 'sample-helmet';

  /// Fixed seed reused on every cold start. Clock-stable epochs so the
  /// "已 X 小时前" labels don't leap forward each launch.
  static final DateTime _seedEpoch = DateTime(2026, 1, 1);

  static final List<ScanRecord> _sampleSeed = <ScanRecord>[
    ScanRecord(
      id: sampleHelmetId,
      name: 'Damaged Helmet · Battle Worn',
      createdAt: _seedEpoch,
      authorHandle: '@kyle',
      caption:
          'PBR sample · scratched plate metal, baked AO, IBL specular. Dawn + Filament reference.',
      preferredCaptureMode: CaptureMode.local,
      artifactPath: 'asset://models/DamagedHelmet.glb',
      bundledGlbAsset: 'DamagedHelmet.glb',
    ),
    ScanRecord(
      id: 'sample-avocado',
      name: 'Hass Avocado',
      createdAt: _seedEpoch,
      authorHandle: '@studio.lin',
      caption:
          'Single avocado, 360° turntable capture · subsurface sheen + bumpy peel preserved.',
      preferredCaptureMode: CaptureMode.newRemote,
      artifactPath: 'asset://models/Avocado.glb',
      bundledGlbAsset: 'Avocado.glb',
    ),
    ScanRecord(
      id: 'sample-boombox',
      name: 'Vintage Boombox',
      createdAt: _seedEpoch,
      authorHandle: '@ana.morales',
      caption:
          'Found at a Brooklyn flea market — chrome dials, dual cassette, label paint chipping.',
      preferredCaptureMode: CaptureMode.newRemote,
      artifactPath: 'asset://models/BoomBox.glb',
      bundledGlbAsset: 'BoomBox.glb',
    ),
    ScanRecord(
      id: 'sample-waterbottle',
      name: 'Hiking Bottle',
      createdAt: _seedEpoch,
      authorHandle: '@trail.dust',
      caption:
          'Anodized aluminum, brushed cap. Caught the morning light just right.',
      preferredCaptureMode: CaptureMode.local,
      artifactPath: 'asset://models/WaterBottle.glb',
      bundledGlbAsset: 'WaterBottle.glb',
    ),
    ScanRecord(
      id: 'sample-duck',
      name: 'Rubber Duck',
      createdAt: _seedEpoch,
      authorHandle: '@tofu',
      caption: 'Bath time mascot. Very smooth, very yellow, mildly judgmental.',
      preferredCaptureMode: CaptureMode.local,
      artifactPath: 'asset://models/Duck.glb',
      bundledGlbAsset: 'Duck.glb',
    ),
    ScanRecord(
      id: 'sample-lantern',
      name: 'Garden Lantern',
      createdAt: _seedEpoch,
      authorHandle: '@nakamura.h',
      caption:
          'Cast iron lantern from a garden in Kyoto, shot at golden hour. Frosted glass + vine details.',
      preferredCaptureMode: CaptureMode.newRemote,
      artifactPath: 'asset://models/Lantern.glb',
      bundledGlbAsset: 'Lantern.glb',
    ),
  ];
}
