import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/eta/eta_prior_log.dart';
import 'package:pocketworld_flutter/eta/pipeline_eta.dart';

void main() {
  test(
    'setUnits before a stage starts re-plans its edges; after it started it is ignored',
    () {
      final priors = EtaPriorLog(
        File('${Directory.systemTemp.path}/nonexistent_eta_log.json'),
      );
      priors.record('b', units: 10, ms: 10000); // 1000 ms per unit
      final eta = PipelineEta(
        stages: const [EtaStage('a', 2), EtaStage('b', 1)],
        priors: priors,
        startMs: 0,
      );
      eta.markUnits('a', 1, 500);
      // Ninja: known = 1 finished (500) + 1 prior (1000) ⇒ avg 750 for the 1 unknown unit of a;
      // remaining = 750 + 1000 ⇒ 1.75 s
      expect(eta.etaSeconds(500), closeTo(1.75, 1e-9));
      eta.setUnits('b', 4); // b really has 4 units
      // known = 1 + 4 priors (4000) ⇒ avg 900 for the unknown unit; remaining = 900 + 4000 ⇒ 4.9 s
      expect(eta.etaSeconds(500), closeTo(4.9, 1e-9));
      eta.setUnits('a', 10); // a already started ⇒ ignored
      expect(eta.etaSeconds(500), closeTo(4.9, 1e-9));
      eta.markStageDone('a', 1000);
      eta.markUnits('b', 2, 3000);
      eta.setUnits('b', 8); // started ⇒ ignored
      expect(eta.unitsDone('b'), 2);
      expect(eta.stages.firstWhere((s) => s.id == 'b').units, 4);
    },
  );
}
