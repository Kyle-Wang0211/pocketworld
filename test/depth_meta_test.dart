import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/depth_alignment_ffi.dart';
import 'package:pocketworld_flutter/capture/depth_meta.dart';

void main() {
  group('DepthMetaEntry', () {
    test('confidence-only entries still derive skip from median', () {
      final stats = DepthConfStats.fromBuffer(const [1.0, 1.0, 1.0, 2.0]);
      final entry = DepthMetaEntry.fromStats(frame: 7, stats: stats);

      expect(entry.skip, isTrue);
      expect(entry.toJson()['schema_version'], kDepthMetaSchemaVersion);
    });

    test('round-trips P0/P1/P2 metric alignment fields', () {
      final entry =
          DepthMetaEntry.fromStats(
            frame: 12,
            stats: const DepthConfStats(
              median: 1.8,
              mean: 2.0,
              min: 1.1,
              max: 4.2,
            ),
            inferenceMs: 123.4,
            relativeDepthPath: 'depth/depth_12.rel.f32',
            metricDepthPath: 'depth/depth_12.metric.f32',
          ).copyWith(
            alignMode: kDepthAlignModeSessionChunkAdaptive,
            alignScale: 1.72,
            alignTranslation: 0.03,
            alignReliability: 0.84,
            alignRmse: 0.012,
            alignInlierRatio: 0.91,
            alignAiDepthSpan: 0.53,
            alignMetricDepthSpan: 0.88,
            alignScalePriorWeight: 0.16,
            alignTranslationPriorWeight: 0.71,
            alignAnchorCount: 74,
            alignAnchorUsed: 69,
            alignUsedPrior: true,
            sparsePriorMode: kSparsePriorModeResidualField,
            sparsePriorUsed: true,
            sparsePriorAnchorCount: 74,
            sparsePriorAnchorUsed: 69,
            sparsePriorMeanAbsResidualM: 0.018,
            sparsePriorMaxAbsResidualM: 0.071,
          );

      final decoded = DepthMetaEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.relativeDepthPath, 'depth/depth_12.rel.f32');
      expect(decoded.metricDepthPath, 'depth/depth_12.metric.f32');
      expect(decoded.alignMode, kDepthAlignModeSessionChunkAdaptive);
      expect(decoded.alignScale, closeTo(1.72, 1e-9));
      expect(decoded.alignTranslation, closeTo(0.03, 1e-9));
      expect(decoded.alignReliability, closeTo(0.84, 1e-9));
      expect(decoded.alignAnchorCount, 74);
      expect(decoded.alignAnchorUsed, 69);
      expect(decoded.alignUsedPrior, isTrue);
      expect(decoded.sparsePriorMode, kSparsePriorModeResidualField);
      expect(decoded.sparsePriorUsed, isTrue);
      expect(decoded.sparsePriorMeanAbsResidualM, closeTo(0.018, 1e-9));
      expect(decoded.sparsePriorMaxAbsResidualM, closeTo(0.071, 1e-9));
    });

    test('native alignment results merge into sidecar entries', () {
      final entry = DepthMetaEntry.fromStats(
        frame: 3,
        stats: const DepthConfStats(median: 2.0, mean: 2.1, min: 1.4, max: 3.8),
      );
      final sparse = SparseDepthPriorResult(
        alignment: const ScaleAlignAdaptiveResult(
          raw: ScaleAlignRawResult(
            scale: 1.9,
            translation: 0.11,
            rmse: 0.02,
            nUsed: 41,
            nInput: 48,
            ok: true,
          ),
          scale: 1.8,
          translation: 0.08,
          reliability: 0.77,
          inlierRatio: 0.85,
          aiDepthSpan: 0.4,
          metricDepthSpan: 0.72,
          scalePriorWeight: 0.23,
          translationPriorWeight: 0.73,
          usedPrior: true,
        ),
        sparseInput: 48,
        sparseUsed: 41,
        meanAbsResidualM: 0.012,
        maxAbsResidualM: 0.056,
        ok: true,
      );

      final merged = sparse.mergeIntoDepthMeta(
        entry,
        metricDepthPath: 'depth/frame_3.metric.f32',
      );

      expect(merged.metricDepthPath, 'depth/frame_3.metric.f32');
      expect(merged.alignScale, closeTo(1.8, 1e-9));
      expect(merged.alignAnchorCount, 48);
      expect(merged.alignAnchorUsed, 41);
      expect(merged.sparsePriorUsed, isTrue);
      expect(merged.sparsePriorMeanAbsResidualM, closeTo(0.012, 1e-9));
    });
  });

  group('DepthMetaSidecar', () {
    test('writes, reads, maps, and ignores malformed tail lines', () async {
      final dir = await Directory.systemTemp.createTemp('depth_meta_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/scan.curated.depth_meta.jsonl';
      final entries = [
        DepthMetaEntry.fromStats(
          frame: 0,
          stats: const DepthConfStats(
            median: 2.0,
            mean: 2.2,
            min: 1.3,
            max: 5.0,
          ),
        ),
        DepthMetaEntry.fromStats(
          frame: 1,
          stats: const DepthConfStats(
            median: 1.0,
            mean: 1.1,
            min: 1.0,
            max: 2.0,
          ),
        ),
      ];

      await DepthMetaSidecar.writeAll(path, entries);
      await File(path).writeAsString('not json\n', mode: FileMode.append);

      final read = await DepthMetaSidecar.read(path);
      final map = await DepthMetaSidecar.readMap(path);

      expect(read.length, 2);
      expect(map.keys, containsAll(<int>[0, 1]));
      expect(DepthMetaSidecar.isFrameSkipped(map, 0), isFalse);
      expect(DepthMetaSidecar.isFrameSkipped(map, 1), isTrue);
      expect(DepthMetaSidecar.isFrameSkipped(map, 999), isFalse);
    });
  });
}
