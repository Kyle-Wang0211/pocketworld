// Flutter port of ScanRecordCell.swift — the waterfall-gallery card.
//
// Visual rules (black & white minimalist — 2026-04-27 direction):
//   • white background, 32pt radius, hairline shadow
//   • thumbnail = local image (will be sourced from the first cell-
//     admitted JPEG in `<captureDir>/photos/` once W3 / Drafts UI
//     populates `record.thumbnailPath`). Gray-gradient placeholder +
//     cube glyph as fallback when no thumbnail is available.
//   • completed badge top-right when `record.artifactPath != null`
//     (W3 has produced a viewable GLB). Plan G W2 全本地 (2026-05-16):
//     the cloud-lifecycle status badges + published-to-community pill
//     are gone with the rest of the cloud chain.
//   • info block: 15pt semibold name + 12pt secondary subtitle.

import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'design_system.dart';
import 'scan_record.dart';

class ScanRecordCell extends StatelessWidget {
  final ScanRecord record;
  final String subtitle;

  /// Fixed thumbnail height; pass null when the cell sits inside a
  /// constraint-bounded parent (e.g. GridView cell with childAspectRatio)
  /// and the thumbnail should expand to fill the remaining space.
  final double? imageHeight;
  final VoidCallback? onTap;

  /// Long-press handler. MePage uses this to show a "delete this scan"
  /// confirmation; the community feed leaves it null since visitors
  /// can't delete other authors' works.
  final VoidCallback? onLongPress;

  /// When true, render the info section with name + subtitle only — hide
  /// author handle + caption. Used by the personal "我的作品" strict-grid
  /// view to keep cards equal height. Community feed and other consumers
  /// keep the default `false` to preserve the richer card.
  final bool minimal;

  /// When true, show the small "已完成" pill on the thumbnail's top-right
  /// once `artifactPath != null`. The community feed leaves this false so
  /// public cards stay clean.
  final bool showCompletedBadge;

  const ScanRecordCell({
    super.key,
    required this.record,
    required this.subtitle,
    this.imageHeight,
    this.onTap,
    this.onLongPress,
    this.minimal = false,
    this.showCompletedBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AetherColors.bgCanvas,
          borderRadius: BorderRadius.circular(AetherRadii.xl),
          boxShadow: [
            BoxShadow(
              color: AetherColors.shadow,
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AetherRadii.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ThumbnailSection(
                record: record,
                imageHeight: imageHeight,
                showCompletedBadge: showCompletedBadge,
              ),
              _InfoSection(
                record: record,
                subtitle: subtitle,
                minimal: minimal,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbnailSection extends StatelessWidget {
  final ScanRecord record;
  final double? imageHeight;
  final bool showCompletedBadge;

  const _ThumbnailSection({
    required this.record,
    required this.imageHeight,
    required this.showCompletedBadge,
  });

  @override
  Widget build(BuildContext context) {
    final stack = Stack(
      fit: StackFit.expand,
      children: [
        _ThumbnailImage(record: record),
        Positioned(
          top: AetherSpacing.md,
          left: AetherSpacing.md,
          child: _PipelineBadge(kind: record.pipelineKind),
        ),
        if (showCompletedBadge && record.hasCompletedArtifact)
          const Positioned(
            top: AetherSpacing.md,
            right: AetherSpacing.md,
            child: _CompletedBadge(),
          ),
      ],
    );
    final h = imageHeight;
    if (h != null) {
      return SizedBox(height: h, child: stack);
    }
    // Null imageHeight → cell sits inside a constrained parent (GridView
    // cell). Use Expanded so the thumbnail fills the leftover space
    // after the info section sizes itself.
    return Expanded(child: stack);
  }
}

class _PipelineBadge extends StatelessWidget {
  const _PipelineBadge({required this.kind});

  final CapturePipelineKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('scan-pipeline-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
      ),
      child: Text(
        kind.displayLabel,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Decides between local thumbnail image (when `record.thumbnailPath`
/// is set and the file exists on disk) and the gray-gradient
/// placeholder. Image load failures (e.g. file deleted out from under
/// us) silently fall through to the placeholder via `errorBuilder`.
class _ThumbnailImage extends StatelessWidget {
  final ScanRecord record;
  const _ThumbnailImage({required this.record});

  @override
  Widget build(BuildContext context) {
    final path = record.thumbnailPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            _PlaceholderThumbnail(mode: record.preferredCaptureMode),
      );
    }
    return _PlaceholderThumbnail(mode: record.preferredCaptureMode);
  }
}

/// Gray-scale gradient placeholder with a subtle dot-grid overlay that
/// visually hints at "point cloud / scanning". Used while a real cover
/// hasn't been generated yet (the first cell-admitted JPEG only lands
/// after the user taps lock-subject + a few seconds of orbit) or if
/// the local thumbnail file is missing.
class _PlaceholderThumbnail extends StatelessWidget {
  final CaptureMode mode;

  const _PlaceholderThumbnail({required this.mode});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: AetherGradients.thumbnailPlaceholder,
          ),
        ),
        const Positioned.fill(
          child: CustomPaint(painter: _DotPointCloudPainter()),
        ),
        Center(
          child: Icon(
            mode.icon,
            size: 36,
            color: Colors.white.withValues(alpha: 0.78),
          ),
        ),
      ],
    );
  }
}

/// Deterministic "point cloud" dots. Stable across rebuilds so the
/// waterfall doesn't flicker.
class _DotPointCloudPainter extends CustomPainter {
  const _DotPointCloudPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.22);
    // Simple hash-walk. Not pretty, just consistent.
    int x = 0x9e3779b1;
    for (int i = 0; i < 110; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      final px = (x % 1000) / 1000.0 * size.width;
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      final py = (x % 1000) / 1000.0 * size.height;
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      final r = 0.7 + (x % 15) / 10.0;
      canvas.drawCircle(Offset(px, py), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DotPointCloudPainter old) => false;
}

// Plan G W2 全本地 (2026-05-16): _StatusBadge + _PublishedBadge
// removed. The cloud-lifecycle "uploading / training / failed" pills
// and the "published to community" globe both required the cloud
// upload chain that's now gone. Only _CompletedBadge survives — it
// fires off `artifactPath != null` (W3 produced a viewable GLB).

class _CompletedBadge extends StatelessWidget {
  const _CompletedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('scan-completed-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AetherRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_rounded,
            size: 12,
            color: AetherColors.primary,
          ),
          const SizedBox(width: 4),
          Text(
            AppL10n.of(context).scanLifecycleCompleted,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AetherColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  final ScanRecord record;
  final String subtitle;
  final bool minimal;

  const _InfoSection({
    required this.record,
    required this.subtitle,
    this.minimal = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Padding(
      padding: const EdgeInsets.all(AetherSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            record.localizedDisplayName(l),
            style: AetherTextStyles.cardTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (!minimal && record.authorHandle != null) ...[
            const SizedBox(height: 2),
            Text(
              record.authorHandle!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AetherColors.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: AetherTextStyles.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (!minimal &&
              record.caption != null &&
              record.caption!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              record.caption!,
              style: AetherTextStyles.bodySm,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
