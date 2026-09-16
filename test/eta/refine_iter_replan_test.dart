// refine_iter_replan_test.dart — the global-BA stage switches from a frame guess to real Ceres iterations the
// moment the core reports progress (page helper _etaRefineProgress mirrors this sequence); priors of the two
// stage ids never mix; the label committed before the switch stays.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/eta/eta_prior_log.dart';
import 'package:pocketworld_flutter/eta/pipeline_eta.dart';

void main() {
  test(
    'frame-guessed refine retires, iteration-counted refine grows with rounds, priors stay separate',
    () async {
      final dir = Directory.systemTemp.createTempSync('pw_eta_iter');
      final priors = EtaPriorLog(File('${dir.path}/log.json'));
      priors.record(
        'sparse.refine',
        units: 21,
        ms: 3800,
      ); // an old run without the signal: 181 ms per FRAME
      final eta = PipelineEta(
        stages: const [
          EtaStage('sparse.drain', 2),
          EtaStage('sparse.refine', 21),
          EtaStage('sparse.refine_iter', 0),
        ],
        priors: priors,
        startMs: 0,
      );
      eta.markStageDone('sparse.drain', 2000);
      final guessed = eta.etaSeconds(
        2000,
      )!; // 21 frames × 181 ms from the old prior
      expect(guessed, closeTo(3.8, 0.05));
      expect(
        eta.labelAt(2000),
        const EtaLabel(0),
      ); // committed on the guess: stays
      // first core tuple: stage 1, round 1, iter 3 of max 50 ⇒ the guess retires, 50 iteration units appear
      eta.setUnits('sparse.refine', 0);
      eta.setUnits('sparse.refine_iter', 50);
      eta.markUnits(
        'sparse.refine_iter',
        3,
        2600,
      ); // 200 ms per iteration so far
      expect(eta.stages.firstWhere((s) => s.id == 'sparse.refine').units, 0);
      // no prior for refine_iter: unknown units take the running average (Ninja)
      expect(
        eta.etaSeconds(2600)!,
        greaterThan(5),
      ); // 47 × ~1.0 s avg (2 drain units of 1 s + 3 iters of 0.2 s)
      // round 2 discovered: units grow to 100 while in progress
      eta.setUnits('sparse.refine_iter', 100);
      eta.markUnits('sparse.refine_iter', 50 + 10, 14000);
      expect(
        eta.stages.firstWhere((s) => s.id == 'sparse.refine_iter').units,
        100,
      );
      expect(eta.unitsDone('sparse.refine_iter'), 60);
      eta.markStageDone('sparse.refine', 22000); // refined arrives: both closed
      eta.markStageDone('sparse.refine_iter', 22000);
      final r = eta.finish(22000);
      expect(r.verdict, isNot(EtaVerdict.uncommitted));
      await priors.save();
      final again = EtaPriorLog(File('${dir.path}/log.json'));
      await again.load();
      expect(
        again.priorUnitMs('sparse.refine'),
        181,
      ); // untouched (0 units this run ⇒ not recorded)
      expect(
        again.priorUnitMs('sparse.refine_iter'),
        200,
      ); // 20000 ms / 100 iterations
      dir.deleteSync(recursive: true);
    },
  );
}
