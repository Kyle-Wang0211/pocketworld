// pw_dense_ffi_isolate_test.dart — the job closure must be sendable to the worker isolate even when a progress
// callback (and therefore a ReceivePort) is in play. On the host there is no PWDense.framework, so the worker
// returns code -1 ("unavailable") — reaching that result at all proves the closure crossed the isolate boundary.
// Build 160 threw "Illegal argument in isolate message: object is unsendable - _ReceivePortImpl" here.
// The same pin covers the v2 chunk callback: onChunk adds a second closure to runPwDenseJob's scope, and the
// job closure must STILL be sendable. On the host no chunk can arrive (no framework, and a v1 framework has no
// pwdense_run2 at all) — the point is that the job reaches its result either way.
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

  test('runPwDenseJob with onChunk too stays sendable (v2 chunk callback)', () async {
    final events = <PwDenseProgress>[];
    final chunks = <PwDenseChunk>[];
    final r = await runPwDenseJob(
      frames: const [
        PwDenseFrame(frameId: 0, fx: 1, fy: 1, cx: 1, cy: 1, imageW: 4, imageH: 3, qWxyz: [1, 0, 0, 0], t: [0, 0, 0], jpegPath: '/nonexistent.jpg'),
      ],
      pointsXyz: const [0.0, 0.0, 1.0],
      workDir: '/tmp/pw_dense_isolate_test',
      outPly: '/tmp/pw_dense_isolate_test.ply',
      onProgress: events.add,
      onChunk: chunks.add,
    );
    expect(r.code, -1);
    expect(r.stats.error, isNotEmpty);
    expect(chunks, isEmpty); // no framework on the host
  });

  // [v3] an NV12 frame carries three more fields across the boundary. On the host there is no framework at all,
  // so the worker still reports "unavailable" — what this pins is that the frame itself is sendable and that the
  // v3 marshalling path is reached without blowing up on the way in.
  test('an NV12 frame (v3) crosses the isolate boundary too', () async {
    final r = await runPwDenseJob(
      frames: const [
        PwDenseFrame(
          frameId: 0,
          fx: 1,
          fy: 1,
          cx: 1,
          cy: 1,
          imageW: 4,
          imageH: 3,
          qWxyz: [1, 0, 0, 0],
          t: [0, 0, 0],
          jpegPath: '',
          nv12Path: '/nonexistent.nv12',
          nv12Width: 4,
          nv12Height: 2,
        ),
      ],
      pointsXyz: const [0.0, 0.0, 1.0],
      workDir: '/tmp/pw_dense_isolate_test',
      outPly: '/tmp/pw_dense_isolate_test.ply',
    );
    expect(r.code, -1); // no framework on the host
    expect(r.stats.error, isNotEmpty);
  });

  test('onChunk alone (no onProgress) also crosses the boundary', () async {
    final chunks = <PwDenseChunk>[];
    final r = await runPwDenseJob(
      frames: const [
        PwDenseFrame(frameId: 0, fx: 1, fy: 1, cx: 1, cy: 1, imageW: 4, imageH: 3, qWxyz: [1, 0, 0, 0], t: [0, 0, 0], jpegPath: '/nonexistent.jpg'),
      ],
      pointsXyz: const [0.0, 0.0, 1.0],
      workDir: '/tmp/pw_dense_isolate_test',
      outPly: '/tmp/pw_dense_isolate_test.ply',
      onChunk: chunks.add,
    );
    expect(r.code, -1);
    expect(chunks, isEmpty);
  });
}
