// ninja_progress_prediction_test.dart — the Dart port reproduces status_printer.cc by hand-computed cases.
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/eta/ninja_progress_prediction.dart';

void main() {
  test('no priors: "?" until the first edge finishes, then running average', () {
    final p = NinjaProgressPrediction();
    for (var i = 0; i < 4; i++) {
      p.edgeAddedToPlan(kNoPrevElapsed);
    }
    p.buildEdgeStarted(0);
    expect(p.etaSeconds(), isNull); // edges_with_known_runtime == 0 → return → pct 0 → "?"
    p.buildEdgeFinished(kNoPrevElapsed, 0, 1000);
    // avg 1000 ms × 3 unknown ⇒ total 4000 ⇒ pct 0.25 ⇒ eta = 1000/0.25 − 1000 = 3000 ms
    expect(p.etaSeconds(), closeTo(3.0, 1e-9));
    expect(p.timePredictedPercentage, closeTo(0.25, 1e-12));
  });

  test('priors: prediction appears with the first finished edge and sums the remaining priors', () {
    final p = NinjaProgressPrediction();
    for (var i = 0; i < 4; i++) {
      p.edgeAddedToPlan(2000);
    }
    p.buildEdgeStarted(0);
    expect(p.etaSeconds(), isNull); // cpu_time 0 ⇒ pct 0 ⇒ "?"
    p.buildEdgeFinished(2000, 0, 500);
    // known = 1 finished + 3 predictable; total = 500 + 6000 ⇒ pct = 500/6500 ⇒ eta = 6000 ms
    expect(p.etaSeconds(), closeTo(6.0, 1e-9));
  });

  test('priors are dropped after 15 s and 5 % done when they are ≥10× off', () {
    final p = NinjaProgressPrediction();
    for (var i = 0; i < 20; i++) {
      p.edgeAddedToPlan(100);
    }
    p.buildEdgeFinished(100, 0, 20000);
    p.buildEdgeFinished(100, 20000, 40000);
    // time 40 s ≥ 15 s, 2/20 = 10 % ≥ 5 %, actual avg 20000 vs prior avg 100 ⇒ ratio 200 ⇒ no priors:
    // unknown 18 × avg 20000 ⇒ remaining 360 s
    expect(p.etaSeconds(), closeTo(360.0, 1e-9));
  });

  test('the same mismatch before 15 s still trusts the priors (gate is time AND share)', () {
    final p = NinjaProgressPrediction();
    for (var i = 0; i < 20; i++) {
      p.edgeAddedToPlan(100);
    }
    p.buildEdgeFinished(100, 0, 5000);
    p.buildEdgeFinished(100, 5000, 10000);
    // priors used: known = 2 + 18, total = 10000 + 1800 ⇒ pct = 10000/11800 ⇒ eta = 1.8 s
    expect(p.etaSeconds(), closeTo(1.8, 1e-9));
  });

  test('a mismatch below 10× keeps the priors after the gate', () {
    final p = NinjaProgressPrediction();
    for (var i = 0; i < 20; i++) {
      p.edgeAddedToPlan(1000);
    }
    p.buildEdgeFinished(1000, 0, 8000);
    p.buildEdgeFinished(1000, 8000, 16000);
    // 16 s, 10 %, ratio 8 < 10 ⇒ priors kept: remaining = 18 × 1000 = 18 s
    expect(p.etaSeconds(), closeTo(18.0, 1e-9));
  });

  test('removing a planned edge reverses the add', () {
    final p = NinjaProgressPrediction();
    p.edgeAddedToPlan(300);
    p.edgeAddedToPlan(kNoPrevElapsed);
    p.edgeRemovedFromPlan(300);
    p.edgeRemovedFromPlan(kNoPrevElapsed);
    expect(p.totalEdges, 0);
    expect(p.etaPredictableEdgesTotal, 0);
    expect(p.etaPredictableCpuTimeTotalMillis, 0);
    expect(p.etaPredictableEdgesRemaining, 0);
    expect(p.etaPredictableCpuTimeRemainingMillis, 0);
    expect(p.etaUnpredictableEdgesRemaining, 0);
  });
}
