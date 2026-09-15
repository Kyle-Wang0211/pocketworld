// ninja_progress_prediction.dart — verbatim port of Ninja's time-weighted progress prediction.
//
// Source: ninja-build/ninja, src/status_printer.cc @ e4a128055f7698522da6de2821ffe0761623f298
// (Apache-2.0, https://github.com/ninja-build/ninja/blob/e4a128055f7698522da6de2821ffe0761623f298/src/status_printer.cc).
// Members copied one-to-one (C++ name → Dart name, same order of operations, same constants):
//   EdgeAddedToPlan                 L91-103
//   EdgeRemovedFromPlan             L105-116
//   BuildEdgeStarted                L118-121   (time_millis_ = start_time_millis)
//   BuildEdgeFinished               L209-224   (the accounting part; printing omitted)
//   RecalculateProgressPrediction   L130-207   (15 s / 5 % / ratio < 10 as in the source)
//   %E ETA formula                  L368-381   total_wall_time = time_millis_ / time_predicted_percentage_;
//                                              eta_sec = (total_wall_time - time_millis_) / 1e3; "?" while the
//                                              percentage is 0.0
// Priors: ninja.cc L356-367 ParsePreviousElapsedTimes — prev_elapsed_time_millis = log end_time − start_time,
// -1 when the build log has no entry for the edge (that sentinel is kept: [kNoPrevElapsed]).
//
// Nothing here is ours: the only additions are Dart typing and [etaSeconds], which is the %E branch.

/// `prev_elapsed_time_millis == -1` — the edge has no previous runtime (graph.h L279).
const int kNoPrevElapsed = -1;

class NinjaProgressPrediction {
  int startedEdges = 0, finishedEdges = 0, totalEdges = 0, runningEdges = 0;

  /// Time the build started (or last refreshed), in ms since the build began. (status_printer.h L74)
  int timeMillis = 0;

  /// Sum of the elapsed times of the finished edges. (status_printer.h L77)
  int cpuTimeMillis = 0;

  /// Percentage of the (predicted) total time spent so far; 0.0 = no prediction. (L80)
  double timePredictedPercentage = 0.0;

  int etaPredictableEdgesTotal = 0; // L83
  int etaPredictableCpuTimeTotalMillis = 0; // L85
  int etaPredictableEdgesRemaining = 0; // L88
  int etaPredictableCpuTimeRemainingMillis = 0; // L90
  int etaUnpredictableEdgesRemaining = 0; // L93

  /// status_printer.cc L91-103.
  void edgeAddedToPlan(int prevElapsedTimeMillis) {
    ++totalEdges;
    // Do we know how long did this edge take last time?
    if (prevElapsedTimeMillis != kNoPrevElapsed) {
      ++etaPredictableEdgesTotal;
      ++etaPredictableEdgesRemaining;
      etaPredictableCpuTimeTotalMillis += prevElapsedTimeMillis;
      etaPredictableCpuTimeRemainingMillis += prevElapsedTimeMillis;
    } else {
      ++etaUnpredictableEdgesRemaining;
    }
  }

  /// status_printer.cc L105-116.
  void edgeRemovedFromPlan(int prevElapsedTimeMillis) {
    --totalEdges;
    if (prevElapsedTimeMillis != kNoPrevElapsed) {
      --etaPredictableEdgesTotal;
      --etaPredictableEdgesRemaining;
      etaPredictableCpuTimeTotalMillis -= prevElapsedTimeMillis;
      etaPredictableCpuTimeRemainingMillis -= prevElapsedTimeMillis;
    } else {
      --etaUnpredictableEdgesRemaining;
    }
  }

  /// status_printer.cc L118-121.
  void buildEdgeStarted(int startTimeMillis) {
    ++startedEdges;
    ++runningEdges;
    timeMillis = startTimeMillis;
  }

  /// status_printer.cc L209-224 (accounting only).
  void buildEdgeFinished(
    int prevElapsedTimeMillis,
    int startTimeMillis,
    int endTimeMillis,
  ) {
    timeMillis = endTimeMillis;
    ++finishedEdges;

    final elapsed = endTimeMillis - startTimeMillis;
    cpuTimeMillis += elapsed;

    // Do we know how long did this edge take last time?
    if (prevElapsedTimeMillis != kNoPrevElapsed) {
      --etaPredictableEdgesRemaining;
      etaPredictableCpuTimeRemainingMillis -= prevElapsedTimeMillis;
    } else {
      --etaUnpredictableEdgesRemaining;
    }
    --runningEdges;
  }

  /// status_printer.cc L130-207, verbatim.
  void recalculateProgressPrediction() {
    timePredictedPercentage = 0.0;

    // Sometimes, the previous and actual times may be wildly different.
    // For example, the previous build may have been fully recovered from ccache,
    // so it was blazing fast, while the new build no longer gets hits from ccache
    // for whatever reason, so it actually compiles code, which takes much longer.
    // We should detect such cases, and avoid using "wrong" previous times.

    // Note that we will only use the previous times if there are edges with
    // previous time knowledge remaining.
    var usePreviousTimes =
        etaPredictableEdgesRemaining != 0 &&
        etaPredictableCpuTimeRemainingMillis != 0;

    // Iff we have sufficient statistical information for the current run,
    // that is, if we have took at least 15 sec AND finished at least 5% of edges,
    // we can check whether our performance so far matches the previous one.
    if (usePreviousTimes &&
        totalEdges != 0 &&
        finishedEdges != 0 &&
        (timeMillis >= 15 * 1e3) &&
        ((finishedEdges / totalEdges) >= 0.05)) {
      // Over the edges we've just run, how long did they take on average?
      final actualAverageCpuTimeMillis = cpuTimeMillis / finishedEdges;
      // What is the previous average, for the edges with such knowledge?
      final previousAverageCpuTimeMillis =
          etaPredictableCpuTimeTotalMillis / etaPredictableEdgesTotal;

      final ratio =
          _max(previousAverageCpuTimeMillis, actualAverageCpuTimeMillis) /
          _min(previousAverageCpuTimeMillis, actualAverageCpuTimeMillis);

      // Let's say that the average times should differ by less than 10x
      usePreviousTimes = ratio < 10;
    }

    var edgesWithKnownRuntime = finishedEdges;
    if (usePreviousTimes) edgesWithKnownRuntime += etaPredictableEdgesRemaining;
    if (edgesWithKnownRuntime == 0) return;

    final edgesWithUnknownRuntime = usePreviousTimes
        ? etaUnpredictableEdgesRemaining
        : (totalEdges - finishedEdges);

    // Given the time elapsed on the edges we've just run,
    // and the runtime of the edges for which we know previous runtime,
    // what's the edge's average runtime?
    var edgesKnownRuntimeTotalMillis = cpuTimeMillis;
    if (usePreviousTimes) {
      edgesKnownRuntimeTotalMillis += etaPredictableCpuTimeRemainingMillis;
    }

    final averageCpuTimeMillis =
        edgesKnownRuntimeTotalMillis / edgesWithKnownRuntime;

    // For the edges for which we do not have the previous runtime,
    // let's assume that their average runtime is the same as for the other edges,
    // and we therefore can predict their remaining runtime.
    final unpredictableCpuTimeRemainingMillis =
        averageCpuTimeMillis * edgesWithUnknownRuntime;

    // And therefore we can predict the remaining and total runtimes.
    var totalCpuTimeRemainingMillis = unpredictableCpuTimeRemainingMillis;
    if (usePreviousTimes) {
      totalCpuTimeRemainingMillis += etaPredictableCpuTimeRemainingMillis;
    }
    final totalCpuTimeMillis = cpuTimeMillis + totalCpuTimeRemainingMillis;
    if (totalCpuTimeMillis == 0.0) return;

    // After that we can tell how much work we've completed, in time units.
    timePredictedPercentage = cpuTimeMillis / totalCpuTimeMillis;
  }

  /// The `%E` branch (status_printer.cc L368-381): null is Ninja's "?".
  double? etaSeconds() {
    recalculateProgressPrediction();
    if (timePredictedPercentage == 0.0) return null;
    // So, we know that we've spent time_millis_ wall clock,
    // and that is time_predicted_percentage_ percent.
    // How much time will we need to complete 100%?
    final totalWallTime = timeMillis / timePredictedPercentage;
    // Naturally, that gives us the time remaining.
    return (totalWallTime - timeMillis) / 1e3;
  }

  static double _max(double a, double b) => a > b ? a : b;
  static double _min(double a, double b) => a < b ? a : b;
}
