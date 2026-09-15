// pw_dense_ffi_isolate_test.dart — the job closure must be sendable to the worker isolate even when a progress
// callback (and therefore a ReceivePort) is in play. On the host there is no PWDense.framework, so the worker
// returns code -1 ("unavailable") — reaching that result at all proves the closure crossed the isolate boundary.
// Build 160 threw "Illegal argument in isolate message: object is unsendable - _ReceivePortImpl" here.
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/pw_dense_ffi.dart';

void main() {
  test('runPwDenseJob with onProgress crosses the isolate boundary (no unsendable capture)', () async {
    final events = <PwDenseProgress>[];
    final r = await runPwDenseJob(
      frames: const [
        PwDenseFrame(frameId: 0, fx: 1, fy: 1, cx: 1, cy: 1, imageW: 4, imageH: 3, qWxyz: [1, 0, 0, 0], t: [0, 0, 0], jpegPath: '/nonexistent.jpg'),
      ],
      pointsXyz: const [0.0, 0.0, 1.0],
      workDir: '/tmp/pw_dense_isolate_test',
      outPly: '/tmp/pw_dense_isolate_test.ply',
      box: const PwDenseBox(cx: 0, cy: 0, cz: 0, sx: 1, sy: 1, sz: 1, rot: [1, 0, 0, 0, 1, 0, 0, 0, 1]),
      onProgress: events.add,
    );
    expect(r.code, -1); // no framework on the host: the worker ran and reported "unavailable"
    expect(r.stats.error, isNotEmpty);
  });
}
