# Zero-Blocking Manual Shutter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept every valid manual-shutter tap immediately, serialize verified 12 MP capture in a memory-bounded FIFO, and remove capture-bar O(N) synchronous disk scans.

**Architecture:** A pure Dart/Flutter `ManualCaptureQueue` owns small capture tickets and runs exactly one asynchronous executor at a time. The capture page enqueues in O(1), keeps the shutter white while work is pending, drains before finalization, and cancels pending tickets on discard. The native ARKit executor, canonical 4032x3024 JPEG persistence, same-frame pose/intrinsics, SfM path spool, and the separate C++ tail-cache work remain unchanged.

**Tech Stack:** Dart 3, Flutter 3.41, `ChangeNotifier`, existing `CaptureSession`, Flutter test, static capture contracts.

---

### Task 1: Add the memory-bounded serial shutter queue

**Files:**
- Create: `lib/official_capture/manual_capture_queue.dart`
- Create: `test/manual_capture_queue_test.dart`

- [ ] **Step 1: Write failing queue tests**

Create tests that enqueue 100 tickets before resolving ticket 1, assert all are accepted, assert executor concurrency never exceeds one, assert FIFO ticket IDs `1..100`, assert freeze rejects new tickets and drains existing tickets, assert cancellation removes not-started tickets, and assert the 300 budget uses `verified + outstanding`.

Use controlled completers rather than timers:

```dart
final gates = List.generate(100, (_) => Completer<void>());
final started = <int>[];
var active = 0;
var maxActive = 0;
final queue = ManualCaptureQueue(
  maxTickets: 300,
  execute: (ticket) async {
    started.add(ticket.id);
    active++;
    maxActive = math.max(maxActive, active);
    await gates[ticket.id - 1].future;
    active--;
  },
  nowMicros: () => 123456,
);
for (var i = 0; i < 100; i++) {
  expect(queue.enqueue(verifiedCount: 0), isTrue);
}
expect(queue.outstandingCount, 100);
await pumpEventQueue();
expect(started, [1]);
expect(maxActive, 1);
```

Also read the production queue source and assert it contains no `dart:typed_data`, `dart:ui`, `Uint8List`, `ByteData`, `Image`, or `CVPixelBuffer` token.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
flutter test --no-pub test/manual_capture_queue_test.dart
```

Expected: FAIL because `manual_capture_queue.dart` and `ManualCaptureQueue` do not exist.

- [ ] **Step 3: Implement the minimal queue**

Create:

```dart
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

class ManualCaptureTicket {
  const ManualCaptureTicket({required this.id, required this.tapTimestampMicros});
  final int id;
  final int tapTimestampMicros;
}

typedef ManualCaptureExecutor = Future<void> Function(ManualCaptureTicket ticket);
typedef ManualCaptureError = void Function(
  ManualCaptureTicket ticket,
  Object error,
  StackTrace stackTrace,
);

class ManualCaptureQueue extends ChangeNotifier {
  ManualCaptureQueue({
    required this.execute,
    required this.maxTickets,
    this.onError,
    int Function()? nowMicros,
  }) : _nowMicros = nowMicros ??
            (() => DateTime.now().microsecondsSinceEpoch);

  final ManualCaptureExecutor execute;
  final ManualCaptureError? onError;
  final int maxTickets;
  final int Function() _nowMicros;
  final Queue<ManualCaptureTicket> _pending = Queue<ManualCaptureTicket>();
  int _nextId = 1;
  ManualCaptureTicket? _active;
  bool _accepting = true;
  bool _pumping = false;
  Completer<void>? _drained;

  int get pendingCount => _pending.length;
  int get inFlightCount => _active == null ? 0 : 1;
  int get outstandingCount => pendingCount + inFlightCount;
  bool get accepting => _accepting;

  bool canEnqueue({required int verifiedCount}) =>
      _accepting && verifiedCount + outstandingCount < maxTickets;

  bool enqueue({required int verifiedCount}) {
    if (!canEnqueue(verifiedCount: verifiedCount)) return false;
    _pending.add(ManualCaptureTicket(
      id: _nextId++,
      tapTimestampMicros: _nowMicros(),
    ));
    notifyListeners();
    unawaited(_pump());
    return true;
  }

  Future<void> freezeAndDrain() {
    _accepting = false;
    notifyListeners();
    if (outstandingCount == 0) return Future<void>.value();
    _drained ??= Completer<void>();
    unawaited(_pump());
    return _drained!.future;
  }

  void resume() {
    _accepting = true;
    notifyListeners();
  }

  void cancelPending() {
    _accepting = false;
    _pending.clear();
    _completeDrainIfEmpty();
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pending.isNotEmpty) {
        _active = _pending.removeFirst();
        notifyListeners();
        final ticket = _active!;
        try {
          await execute(ticket);
        } catch (error, stackTrace) {
          onError?.call(ticket, error, stackTrace);
        } finally {
          _active = null;
          notifyListeners();
        }
      }
    } finally {
      _pumping = false;
      _completeDrainIfEmpty();
    }
  }

  void _completeDrainIfEmpty() {
    if (outstandingCount != 0) return;
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }
}
```

The queue catches every executor exception, calls `onError(ticket, error,
stackTrace)`, and continues with the next still-pending ticket. The page's error
callback records telemetry and shows a persistent capture fault. The production
transaction retries at most six times inside one queue slot; exhaustion is
therefore explicit and cannot strand Finish indefinitely.

- [ ] **Step 4: Run queue tests and verify GREEN**

Run:

```bash
dart format lib/official_capture/manual_capture_queue.dart test/manual_capture_queue_test.dart
flutter test --no-pub test/manual_capture_queue_test.dart
```

Expected: PASS; all 100 tickets accepted, ordered, and executed at concurrency 1.

### Task 2: Integrate FIFO admission into the capture page

**Files:**
- Modify: `lib/ui/official_capture/ar_capture_page.dart`
- Modify: `test/official_highres_reconstruction_contract_test.dart`
- Modify: `test/official_capture_frame_budget_contract_test.dart`

- [ ] **Step 1: Reverse the obsolete lock contract and verify RED**

Replace the old assertion that requires `await capture.highResolutionCompletion`
inside `_onShutterTap` with assertions that:

```dart
expect(page, isNot(contains('if (_capturing) return;')));
expect(page, isNot(contains('setState(() => _capturing = true)')));
expect(page, contains('_shutterQueue.enqueue('));
expect(page, contains('Future<void> _executeShutterTicket('));
expect(page, contains('await capture.highResolutionCompletion'));
expect(page, contains('await _shutterQueue.freezeAndDrain()'));
```

Update the frame-budget contract so the cap includes the queue's outstanding
count and the sole capture call lives in `_executeShutterTicket`.

Run:

```bash
flutter test --no-pub \
  test/official_highres_reconstruction_contract_test.dart \
  test/official_capture_frame_budget_contract_test.dart
```

Expected: FAIL because the page still drops taps and has no queue.

- [ ] **Step 2: Add O(1) admission and serial execution**

Import `manual_capture_queue.dart`, create a late queue in `initState`, and move
the old asynchronous photo body to `_executeShutterTicket(ticket)`. Make
`_onShutterTap` synchronous: it validates the ready/cap state and enqueues one
ticket without awaiting camera, disk, or SfM work.

The executor must retain the existing call sequence:

```dart
final capture = await session.captureSinglePhoto();
if (capture == null) {
  throw StateError('accepted shutter ticket could not start');
}
unawaited(_arKitChannel.invokeMethod<void>('addPhotoCard', ...));
await capture.highResolutionCompletion;
```

Telemetry adds ticket ID, tap timestamp, queue wait, and actual capture result;
the image continues using the native returned capture timestamp and pose.

- [ ] **Step 3: Keep the shutter white while pending**

Pass `ManualCaptureQueue` to `_ManualCaptureBar`, merge it with the album
listenable, compute cap availability from:

```dart
officialCaptureCanShoot(
  acceptedFrameCount: projectPhotos.count + shutterQueue.outstandingCount,
)
```

Remove `_ShutterButton.busy` and render its inner circle as `Colors.white`.
The tap handler remains non-null while the session is ready, admission is open,
and the combined cap is below 300.

- [ ] **Step 4: Drain before finish and cancel on discard/dispose**

At finish, freeze admission and await the queue before minimum-photo, starved,
`session.stop()`, or SfM-finalize logic. Resume admission if the user chooses to
continue capturing and the camera has not failed to resume. On confirmed
discard or page disposal, cancel pending work, stop active retry, drain its file
ownership, then delete/dispose. Backgrounding suspends the active ticket before
ARKit stops and reopens it only after a successful ARKit resume. Remove
`_capturing` from close and lifecycle gates.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
dart format lib/ui/official_capture/ar_capture_page.dart \
  test/official_highres_reconstruction_contract_test.dart \
  test/official_capture_frame_budget_contract_test.dart
flutter test --no-pub \
  test/manual_capture_queue_test.dart \
  test/official_highres_reconstruction_contract_test.dart \
  test/official_capture_frame_budget_contract_test.dart \
  test/manual_capture_startup_race_contract_test.dart
```

Expected: PASS; startup-race fix remains present.

### Task 3: Remove capture-bar O(N) synchronous disk scans

**Files:**
- Modify: `lib/official_capture/project_photo_album.dart`
- Modify: `lib/ui/official_capture/ar_capture_page.dart`
- Modify: `test/official_project_photo_album_test.dart`
- Create: `test/manual_capture_bar_io_contract_test.dart`

- [ ] **Step 1: Write latest-path and no-build-I/O tests, then verify RED**

Add album tests proving `latestPath` is null initially, becomes the last verified
commit, rolls back after deleting the latest photo, and clears to null. Add a
source contract extracting `_ManualCaptureBar` and rejecting `File(`,
`existsSync`, `lastModifiedSync`, and `.paths` in its build implementation.

Run:

```bash
flutter test --no-pub \
  test/official_project_photo_album_test.dart \
  test/manual_capture_bar_io_contract_test.dart
```

Expected: FAIL because `latestPath` is absent and the builder scans files.

- [ ] **Step 2: Add cached latest path and remove scanning**

Add:

```dart
String? get latestPath => _photos.isEmpty ? null : _photos.last.jpegPath;
```

Replace the capture-bar `paths/existsSync/lastModifiedSync` loop with
`projectPhotos.latestPath`. Keep file existence/length validation only in the
one-time `commitVerified` boundary. The finish button uses
`projectPhotos.count == 0`, not a rebuilt file list.

- [ ] **Step 3: Run tests and verify GREEN**

Run:

```bash
dart format lib/official_capture/project_photo_album.dart \
  lib/ui/official_capture/ar_capture_page.dart \
  test/official_project_photo_album_test.dart \
  test/manual_capture_bar_io_contract_test.dart
flutter test --no-pub \
  test/official_project_photo_album_test.dart \
  test/manual_capture_bar_io_contract_test.dart
```

Expected: PASS and no synchronous file operation inside `_ManualCaptureBar`.

### Task 4: Regression verification and review

**Files:**
- Verify only the files above; do not modify C++ tail-cache/dirty-epoch files.

- [ ] **Step 1: Run the complete focused capture suite**

```bash
flutter test --no-pub \
  test/manual_capture_queue_test.dart \
  test/manual_capture_bar_io_contract_test.dart \
  test/official_project_photo_album_test.dart \
  test/official_highres_reconstruction_contract_test.dart \
  test/official_capture_frame_budget_contract_test.dart \
  test/manual_capture_startup_race_contract_test.dart \
  test/official_photo_user_control_contract_test.dart \
  test/official_capture_twenty_frame_ui_contract_test.dart
```

Expected: all tests pass.

- [ ] **Step 2: Analyze only changed production files**

```bash
flutter analyze --no-pub \
  lib/official_capture/manual_capture_queue.dart \
  lib/official_capture/project_photo_album.dart \
  lib/ui/official_capture/ar_capture_page.dart
```

Expected: no new errors; any pre-existing warnings are itemized separately.

- [ ] **Step 3: Inspect the scoped diff and prove tail-cache non-interference**

```bash
git diff --check -- \
  lib/official_capture/manual_capture_queue.dart \
  lib/official_capture/project_photo_album.dart \
  lib/ui/official_capture/ar_capture_page.dart \
  test/manual_capture_queue_test.dart \
  test/manual_capture_bar_io_contract_test.dart \
  test/official_project_photo_album_test.dart \
  test/official_highres_reconstruction_contract_test.dart \
  test/official_capture_frame_budget_contract_test.dart
```

Expected: exit 0. Confirm no file under `Aether3D-cross`, `vendor/official_sfm`,
or the tail-cache work's C++ ownership set was changed by this task.

- [ ] **Step 4: Obtain fresh read-only review**

The reviewer receives the design, plan, exact scoped diff, RED/GREEN logs, and
test output without author persuasion. Acceptance is P0=0/P1=0. Any queue tap
loss, concurrent native request, raw-image retention, finalize-before-drain,
300-cap overshoot, or synchronous capture-bar scan is P1.

- [ ] **Step 5: Stop before device installation**

Prepare an unsigned candidate and exact evidence only after review. Do not
build/sign/install the production iPhone app without a new exact P3 scope and
authorization.
