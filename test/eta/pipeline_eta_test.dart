// pipeline_eta_test.dart — commit-once labels, buckets, the ruler, and the prior log round trip.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/eta/eta_prior_log.dart';
import 'package:pocketworld_flutter/eta/ninja_progress_prediction.dart';
import 'package:pocketworld_flutter/eta/pipeline_eta.dart';

void main() {
  test('label buckets: under a minute, then minutes rounded up', () {
    expect(EtaLabel.bucket(0), const EtaLabel(0));
    expect(EtaLabel.bucket(59.9), const EtaLabel(0));
    expect(EtaLabel.bucket(60), const EtaLabel(1));
    expect(EtaLabel.bucket(61), const EtaLabel(2));
    expect(EtaLabel.bucket(180), const EtaLabel(3));
    expect(const EtaLabel(0).upperBoundSec, 60);
    expect(const EtaLabel(3).lowerBoundSec, 120);
    expect(const EtaLabel(3).upperBoundSec, 180);
  });

  test('"计算中…" until the first prediction, then the label is committed and never changes', () {
    final priors = EtaPriorLog(File('${Directory.systemTemp.path}/nonexistent_eta_log.json'));
    final eta = PipelineEta(
      stages: const [EtaStage('drain', 5), EtaStage('refine', 5)],
      priors: priors,
      startMs: 1000,
    );
    expect(eta.labelAt(1500), isNull); // nothing finished, no priors ⇒ "?"
    eta.markUnits('drain', 1, 2000); // 1 s per unit ⇒ 9 unknown units ⇒ ~9 s ⇒ under a minute
    final first = eta.labelAt(2000);
    expect(first, const EtaLabel(0));
    expect(eta.committedAtMs, 2000);
    // the job then slows down massively: the label must not move
    eta.markUnits('drain', 2, 60000);
    expect(eta.labelAt(60000), const EtaLabel(0));
    expect(eta.etaSeconds(60000), greaterThan(60)); // the raw estimate did move
  });

  test('ruler: ok within the bucket, late beyond +10 %, early below the lower bound', () {
    EtaRulerResult run({required double etaAtCommitSec, required int finishAfterMs}) {
      final priors = EtaPriorLog(File('${Directory.systemTemp.path}/nonexistent_eta_log.json'));
      // one stage of 2 units with a prior chosen so the first prediction equals etaAtCommitSec
      final priorMs = (etaAtCommitSec * 1000).round();
      priors.record('x', units: 2, ms: 2 * priorMs);
      final eta = PipelineEta(stages: const [EtaStage('x', 2)], priors: priors, startMs: 0);
      // first unit finishes instantly-ish so the estimate ≈ prior of the remaining unit
      eta.markUnits('x', 1, 1);
      final label = eta.labelAt(1);
      expect(label, isNotNull);
      return eta.finish(1 + finishAfterMs);
    }

    expect(run(etaAtCommitSec: 30, finishAfterMs: 45000).verdict, EtaVerdict.ok);
    expect(run(etaAtCommitSec: 30, finishAfterMs: 66000).verdict, EtaVerdict.ok); // exactly +10 %
    expect(run(etaAtCommitSec: 30, finishAfterMs: 66001).verdict, EtaVerdict.late);
    expect(run(etaAtCommitSec: 150, finishAfterMs: 119000).verdict, EtaVerdict.early); // "约 3 分钟", done in 119 s
    expect(run(etaAtCommitSec: 150, finishAfterMs: 121000).verdict, EtaVerdict.ok);
    expect(run(etaAtCommitSec: 150, finishAfterMs: 198001).verdict, EtaVerdict.late);
  });

  test('never committed ⇒ uncommitted verdict, not a failure count', () {
    final priors = EtaPriorLog(File('${Directory.systemTemp.path}/nonexistent_eta_log.json'));
    final eta = PipelineEta(stages: const [EtaStage('x', 1)], priors: priors, startMs: 0);
    final r = eta.finish(500);
    expect(r.verdict, EtaVerdict.uncommitted);
    expect(r.pass, isFalse);
  });

  test('finish records each stage duration as the next run\'s prior; log round-trips through disk', () async {
    final dir = Directory.systemTemp.createTempSync('pw_eta_log');
    final f = File('${dir.path}/log.json');
    final priors = EtaPriorLog(f);
    await priors.load();
    expect(priors.priorUnitMs('sparse.drain'), kNoPrevElapsed);
    final eta = PipelineEta(
      stages: const [EtaStage('sparse.drain', 4), EtaStage('sparse.refine', 4)],
      priors: priors,
      startMs: 0,
    );
    eta.markUnits('sparse.drain', 2, 1000);
    eta.markUnits('sparse.drain', 4, 2000);
    eta.markStageDone('sparse.refine', 6000);
    eta.finish(6000);
    await priors.save();
    final again = EtaPriorLog(f);
    await again.load();
    expect(again.priorUnitMs('sparse.drain'), 500); // 2000 ms / 4
    expect(again.priorUnitMs('sparse.refine'), 1000); // 4000 ms / 4
    // second run: priors make a prediction available as soon as one unit finished
    final eta2 = PipelineEta(
      stages: const [EtaStage('sparse.drain', 4), EtaStage('sparse.refine', 4)],
      priors: again,
      startMs: 0,
    );
    expect(eta2.labelAt(10), isNull);
    eta2.markUnits('sparse.drain', 1, 500);
    // remaining priors: 3×500 + 4×1000 = 5500 ms ⇒ under a minute
    expect(eta2.etaSeconds(500), closeTo(5.5, 1e-9));
    expect(eta2.labelAt(500), const EtaLabel(0));
    dir.deleteSync(recursive: true);
  });

  test('a corrupt log file is treated as empty', () async {
    final dir = Directory.systemTemp.createTempSync('pw_eta_log2');
    final f = File('${dir.path}/log.json')..writeAsStringSync('{not json');
    final priors = EtaPriorLog(f);
    await priors.load();
    expect(priors.entries, isEmpty);
    dir.deleteSync(recursive: true);
  });
}
