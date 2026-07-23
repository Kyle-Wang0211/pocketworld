// Dart port of the TestFlight prototype's ScanRecord + ScanJobStatus.
// Fields intentionally minimal — only the ones the current placeholder
// UI actually reads. When the Flutter app starts talking to a real
// backend / ScanRecordStore, extend this model and the view model that
// wraps it; the UI layer stays stable.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Immutable identity of the end-to-end capture stack that owns a scan.
///
/// This is deliberately separate from [CaptureMode]: capture mode describes
/// where processing happens, while pipeline kind selects the independent
/// self-developed or official-alignment implementation.
enum CapturePipelineKind { self, official }

extension CapturePipelineKindWire on CapturePipelineKind {
  String get wireName {
    switch (this) {
      case CapturePipelineKind.self:
        return 'self';
      case CapturePipelineKind.official:
        return 'official';
    }
  }

  String get displayLabel {
    switch (this) {
      case CapturePipelineKind.self:
        return '自研';
      case CapturePipelineKind.official:
        return '官方';
    }
  }

  /// Parses an explicitly present wire value.
  ///
  /// Legacy migration is intentionally not handled here: callers may map a
  /// completely absent field to [CapturePipelineKind.self], but an explicitly
  /// present null, wrong type, or unknown string must fail closed.
  static CapturePipelineKind fromWireName(Object? value) {
    switch (value) {
      case 'self':
        return CapturePipelineKind.self;
      case 'official':
        return CapturePipelineKind.official;
      default:
        throw FormatException('Invalid pipeline_kind: $value');
    }
  }
}

// 2026-05-21: cloud capture upload is back, but as a frame-first staging
// channel (JPG/JSON + cloud manifest), not the deleted .mov upload chain.
// These states describe the raw-capture handoff only; training/packaging
// still belongs to the server-side scans/works lifecycle.

enum ScanCloudUploadStatus {
  none,
  localPending,
  uploading,
  uploaded,
  acknowledged,
  queued,
  processing,
  completed,
  failed,
}

extension ScanCloudUploadStatusWire on ScanCloudUploadStatus {
  String get wireName {
    switch (this) {
      case ScanCloudUploadStatus.none:
        return 'none';
      case ScanCloudUploadStatus.localPending:
        return 'local_pending';
      case ScanCloudUploadStatus.uploading:
        return 'uploading';
      case ScanCloudUploadStatus.uploaded:
        return 'uploaded';
      case ScanCloudUploadStatus.acknowledged:
        return 'acknowledged';
      case ScanCloudUploadStatus.queued:
        return 'queued';
      case ScanCloudUploadStatus.processing:
        return 'processing';
      case ScanCloudUploadStatus.completed:
        return 'completed';
      case ScanCloudUploadStatus.failed:
        return 'failed';
    }
  }

  static ScanCloudUploadStatus fromWireName(String? value) {
    switch (value) {
      case 'local_pending':
        return ScanCloudUploadStatus.localPending;
      case 'uploading':
        return ScanCloudUploadStatus.uploading;
      case 'uploaded':
        return ScanCloudUploadStatus.uploaded;
      case 'uploaded_acknowledged':
      case 'acknowledged':
        return ScanCloudUploadStatus.acknowledged;
      case 'pending':
      case 'queued':
        return ScanCloudUploadStatus.queued;
      case 'processing':
      case 'training':
      case 'packaging':
      case 'artifact_ready':
        return ScanCloudUploadStatus.processing;
      case 'completed':
        return ScanCloudUploadStatus.completed;
      case 'failed':
        return ScanCloudUploadStatus.failed;
      case 'none':
      default:
        return ScanCloudUploadStatus.none;
    }
  }
}

extension CaptureModeL10n on CaptureMode {
  String localizedTitle(AppL10n l) {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return l.captureModeRemoteLegacy;
      case CaptureMode.newRemote:
        return l.captureModeNewRemote;
      case CaptureMode.local:
        return l.captureModeLocal;
    }
  }
}

/// Which capture pipeline produced (or will produce) this record. Mirrors
/// the prototype's AetherCaptureMode. Stays client-side; the backend
/// doesn't see this distinction directly (the upload broker picks the
/// pipeline based on the mode the client selected at capture time).
enum CaptureMode {
  /// Legacy remote pipeline — for backward-compat validation.
  remoteLegacy,

  /// New remote (recommended default). Preview-first, HQ-upgrade flow.
  newRemote,

  /// Local-only pipeline. Runs on-device, fastest feedback, no cloud.
  local,
}

extension CaptureModeLabel on CaptureMode {
  String get title {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '远端方案';
      case CaptureMode.newRemote:
        return '新远端';
      case CaptureMode.local:
        return '本地方案';
    }
  }

  String get subtitle {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '兼容旧版云端高质量处理链路，适合对照验证。';
      case CaptureMode.newRemote:
        return '对象模式 Beta，先出 Preview，再升级成 Default 与 HQ。';
      case CaptureMode.local:
        return '本地扫描链路，适合快速验证、低延迟预览和离线调试。';
    }
  }

  String get detailTitle {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '适合继续跑远端兼容性样本';
      case CaptureMode.newRemote:
        return '适合作为新版主入口';
      case CaptureMode.local:
        return '适合现场快速确认采集效果';
    }
  }

  String get detailBody {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '拍摄完成后走旧版远端处理，结果稳定，但反馈速度相对慢一些。';
      case CaptureMode.newRemote:
        return '拍摄后系统会优先返回 Preview，方便先做质量判断，再等待更高质量版本。';
      case CaptureMode.local:
        return '拍摄结束后优先保留本地成果，适合不稳定网络环境或临时验证。';
    }
  }

  String? get shortBadge {
    switch (this) {
      case CaptureMode.newRemote:
        return '推荐';
      case CaptureMode.remoteLegacy:
      case CaptureMode.local:
        return null;
    }
  }

  IconData get icon {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return Icons.cloud_outlined;
      case CaptureMode.newRemote:
        return Icons.auto_awesome_rounded;
      case CaptureMode.local:
        return Icons.phone_iphone_rounded;
    }
  }
}

/// One scan record, either in-progress capture or finished local GLB.
/// Immutable data container; ViewModels hold lists of these.
///
/// Plan G W2 全本地 (2026-05-16): drop all cloud-lifecycle fields
/// (jobId, jobStatus, pipelineStage, publishedWorkId, videoSizeBytes,
/// failureMessage). Local-only schema = id + name + thumbnail + GLB
/// path. JSON deserializer silently drops legacy cloud fields so the
/// existing on-disk scan_records.json keeps loading.
@immutable
class ScanRecord {
  final String id;
  final String name;
  final DateTime createdAt;
  final CapturePipelineKind pipelineKind;
  final CaptureMode preferredCaptureMode;

  /// Null for now (no real image pipeline). Kept so ScanRecordCell can
  /// branch on it and the eventual W3 local GLB pipeline has a landing
  /// spot without a schema change.
  final String? thumbnailPath;

  /// Path to the viewer-ready GLB on disk. `file://` URL for records
  /// produced by the user's own captures (W3 local pipeline writes to
  /// `app_documents/scans/<id>.glb`); `asset://` URL for seeded sample
  /// records.
  final String? artifactPath;

  /// Capture session root containing `photos/` and stage outputs. Present
  /// for local drafts before W3 produces a GLB.
  final String? captureDir;

  /// Curated capture photos directory. Contains sibling
  /// `cell_<i>_slot_<j>.jpg/json` files.
  final String? photosDir;

  /// Capture-side manifest written next to `photos/`. This is the bridge
  /// from the Drafts UI entry back to the raw JPEG + ARKit metadata bundle.
  final String? captureManifestPath;

  /// Number of curated JPEG frames retained for this draft.
  final int? photoCount;

  /// Cloud upload state for the raw capture bundle. Local paths remain
  /// valid while this is pending/failed; in beta we intentionally keep
  /// them after upload too so DA3 pipeline experiments can be rerun.
  final ScanCloudUploadStatus cloudUploadStatus;
  final String? cloudScanId;
  final String? cloudManifestPath;
  final String? cloudWorkId;
  final String? cloudArtifactPath;
  final int? uploadedFrameCount;
  final DateTime? uploadedAt;
  final DateTime? localRawDeletedAt;
  final DateTime? cloudRawDeletedAt;
  final String? cloudUploadFailureMessage;
  final bool localRawRetainedForDebug;

  /// Author display handle. Mock data for the social-feed demo.
  final String? authorHandle;

  /// Author one-line caption shown under the work title in the social
  /// feed. Free-form user-authored text; **not** translated (treated like
  /// the work name itself).
  final String? caption;

  /// Bundled GLB asset (under `assets/models/`) the viewer should load
  /// when this card is tapped. Null = no preview model yet (e.g. W3 not
  /// yet run). Used by Vault → CapturePage(viewer mode) to swap the
  /// Dawn scene without spinning up a new IOSurface.
  final String? bundledGlbAsset;

  const ScanRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    this.pipelineKind = CapturePipelineKind.self,
    this.preferredCaptureMode = CaptureMode.local,
    this.thumbnailPath,
    this.artifactPath,
    this.captureDir,
    this.photosDir,
    this.captureManifestPath,
    this.photoCount,
    this.cloudUploadStatus = ScanCloudUploadStatus.none,
    this.cloudScanId,
    this.cloudManifestPath,
    this.cloudWorkId,
    this.cloudArtifactPath,
    this.uploadedFrameCount,
    this.uploadedAt,
    this.localRawDeletedAt,
    this.cloudRawDeletedAt,
    this.cloudUploadFailureMessage,
    this.localRawRetainedForDebug = false,
    this.authorHandle,
    this.caption,
    this.bundledGlbAsset,
  });

  /// Returns a copy with the supplied fields overridden. `null` values
  /// keep the existing field — to clear a value pass `clearXxx: true`.
  ScanRecord copyWith({
    String? name,
    String? thumbnailPath,
    bool clearThumbnailPath = false,
    String? artifactPath,
    bool clearArtifactPath = false,
    String? captureDir,
    String? photosDir,
    String? captureManifestPath,
    int? photoCount,
    ScanCloudUploadStatus? cloudUploadStatus,
    String? cloudScanId,
    String? cloudManifestPath,
    String? cloudWorkId,
    String? cloudArtifactPath,
    int? uploadedFrameCount,
    DateTime? uploadedAt,
    DateTime? localRawDeletedAt,
    DateTime? cloudRawDeletedAt,
    String? cloudUploadFailureMessage,
    bool clearCloudUploadFailureMessage = false,
    bool? localRawRetainedForDebug,
    String? caption,
  }) {
    return ScanRecord(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      pipelineKind: pipelineKind,
      preferredCaptureMode: preferredCaptureMode,
      thumbnailPath: clearThumbnailPath
          ? null
          : (thumbnailPath ?? this.thumbnailPath),
      artifactPath: clearArtifactPath
          ? null
          : (artifactPath ?? this.artifactPath),
      captureDir: captureDir ?? this.captureDir,
      photosDir: photosDir ?? this.photosDir,
      captureManifestPath: captureManifestPath ?? this.captureManifestPath,
      photoCount: photoCount ?? this.photoCount,
      cloudUploadStatus: cloudUploadStatus ?? this.cloudUploadStatus,
      cloudScanId: cloudScanId ?? this.cloudScanId,
      cloudManifestPath: cloudManifestPath ?? this.cloudManifestPath,
      cloudWorkId: cloudWorkId ?? this.cloudWorkId,
      cloudArtifactPath: cloudArtifactPath ?? this.cloudArtifactPath,
      uploadedFrameCount: uploadedFrameCount ?? this.uploadedFrameCount,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      localRawDeletedAt: localRawDeletedAt ?? this.localRawDeletedAt,
      cloudRawDeletedAt: cloudRawDeletedAt ?? this.cloudRawDeletedAt,
      cloudUploadFailureMessage: clearCloudUploadFailureMessage
          ? null
          : (cloudUploadFailureMessage ?? this.cloudUploadFailureMessage),
      localRawRetainedForDebug:
          localRawRetainedForDebug ?? this.localRawRetainedForDebug,
      authorHandle: authorHandle,
      caption: caption ?? this.caption,
      bundledGlbAsset: bundledGlbAsset,
    );
  }

  bool get hasCompletedArtifact => artifactPath != null;
}

/// Locale-aware display-name resolver.
///
/// Storage layer hardcodes the default name in Chinese for legacy
/// reasons ("未命名(N)" from upload_coordinator, "导入的模型" from
/// import_glb_coordinator). Migrating every old stored record is
/// risky; instead we detect those exact default patterns at display
/// time and substitute the locale-appropriate string. A user who
/// explicitly renames the record (e.g. "玩具" / "Yoda" / anything that
/// doesn't match the regex) falls through unchanged.
///
/// New unnamed records continue to be stored as "未命名(N)" so old +
/// new records render the same way under either locale. Cross-locale
/// switching at runtime is automatic.
extension ScanRecordL10n on ScanRecord {
  String localizedDisplayName(AppL10n l) {
    // "未命名(N)" or "Untitled(N)" → re-render with locale.
    final m = RegExp(r'^(?:未命名|Untitled)\((\d+)\)$').firstMatch(name);
    if (m != null) {
      return '${l.defaultUntitledScan}(${m.group(1)})';
    }
    // "导入的模型" or "Imported model" — exact match, no number.
    if (name == '导入的模型' || name == 'Imported model') {
      return l.defaultImportedScan;
    }
    return name;
  }
}
