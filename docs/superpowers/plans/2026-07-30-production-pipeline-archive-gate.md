# Production Pipeline Archive Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Per the user's explicit instruction, this plan is executed inline by the primary agent without subagents.

**Goal:** Guarantee that JPEG XL and ZPAQ cold archival never starts new work while any official capture or point-cloud production pipeline is active, and automatically resumes after the last production activity ends.

**Architecture:** `PhotoArchiveCoordinator` remains the single Dart owner of compression scheduling. Capture and reconstruction keep using their existing activity leases, but the coordinator exposes the production-gate state, uses it at every archive boundary, cancels interruptible database work, and waits for an in-flight pump to reach a safe boundary before restarting queued work after the final lease closes.

**Tech Stack:** Dart, Flutter test, existing JPEG XL/ZPAQ transaction layer, existing append-only archive audit store.

---

### Task 1: Lock the production-gate contract with failing tests

**Files:**
- Modify: `test/photo_archive_coordinator_test.dart`
- Modify: `test/database_archive_coordinator_test.dart`

- [x] **Step 1: Add a multi-lease state test**

Add a coordinator test that acquires capture and reconstruction leases together
and verifies that the gate stays closed until both leases are released:

```dart
test('production gate remains active until every pipeline lease closes', () async {
  final capture = await createCompleteCapture('multi-lease', marked: true);
  final coordinator = PhotoArchiveCoordinator(codec: _ZlibCoordinatorCodec());

  final recording = coordinator.beginCaptureActivity();
  final reconstruction = coordinator.beginReconstructionActivity(capture);

  expect(coordinator.isProductionPipelineActive, isTrue);
  expect(coordinator.activeProductionPipelineCount, 2);

  await recording.close();
  expect(coordinator.isProductionPipelineActive, isTrue);
  expect(coordinator.activeProductionPipelineCount, 1);

  await reconstruction.close();
  expect(coordinator.isProductionPipelineActive, isFalse);
  expect(coordinator.activeProductionPipelineCount, 0);
});
```

- [x] **Step 2: Add the cancellation/release race regression**

Start a blocking database compression, acquire and immediately release a
production lease, and require the coordinator to retry automatically after the
cancelled transaction reaches its safe boundary:

```dart
test('release during cancellation automatically resumes queued database work', () async {
  final capture = await createReadyCapture(
    'cancel-release-race',
    photoMarked: false,
    databaseMarked: true,
  );
  final databaseCodec = _BlockingDatabaseCodec();
  final coordinator = PhotoArchiveCoordinator(
    codec: _ZlibPhotoCodec(),
    databaseCodec: databaseCodec,
  );

  final archiveFuture = coordinator.noteArtifactsPersisted(capture);
  await databaseCodec.started.future;
  final lease = coordinator.beginCaptureActivity();
  await lease.close();
  await archiveFuture;

  expect(databaseCodec.cancellationRequests, 1);
  expect(databaseCodec.compressCalls, 2);
  expect(
    await File(
      '${capture.path}/${DatabaseArchivePolicy.sourceFileName}',
    ).exists(),
    isFalse,
  );
  expect(
    await File(
      '${capture.path}/${DatabaseArchivePolicy.sourceFileName}.zpaq',
    ).exists(),
    isTrue,
  );
});
```

- [x] **Step 3: Run the focused tests and verify RED**

Run:

```bash
flutter test test/photo_archive_coordinator_test.dart test/database_archive_coordinator_test.dart
```

Expected: failure because the public production-gate getters do not exist and
because an immediately released lease does not currently restart work requeued
after database cancellation.

### Task 2: Implement the production gate and safe automatic restart

**Files:**
- Modify: `lib/official_capture/photo_archive_coordinator.dart`

- [x] **Step 1: Name and expose the gate state**

Replace the ambiguous foreground counter with production-pipeline state:

```dart
int _activeProductionPipelineCount = 0;

bool get isProductionPipelineActive =>
    _activeProductionPipelineCount != 0;

int get activeProductionPipelineCount =>
    _activeProductionPipelineCount;
```

Use `!isProductionPipelineActive` in the queue loop and in both transaction
continuation callbacks so photos stop before the next file and database work
stops at its cancellation/verification boundary.

- [x] **Step 2: Centralize lease release**

Both capture and reconstruction leases call a single release helper. The helper
removes reconstruction ownership where applicable, waits for the current pump
to observe cancellation, and starts pending work only after the final
production lease has closed:

```dart
Future<void> _releaseProductionActivity({
  Directory? reconstructionDirectory,
}) async {
  if (_activeProductionPipelineCount > 0) {
    _activeProductionPipelineCount--;
  }
  if (reconstructionDirectory != null) {
    final path = _canonicalKey(reconstructionDirectory);
    _reconstructionOwners.remove(path);
    _pending[path] = reconstructionDirectory.absolute;
  }
  if (isProductionPipelineActive) return;

  final active = _pumpFuture;
  if (active != null) await active;
  if (_pending.isNotEmpty) await _pumpQueue();
}
```

The source deletion rules remain unchanged: a JPEG source is deleted only after
byte-for-byte reconstruction, SHA-256 verification, archive rename, and atomic
manifest commit; database cancellation removes only temporary files.

- [x] **Step 3: Run focused tests and verify GREEN**

Run:

```bash
flutter test test/photo_archive_coordinator_test.dart test/database_archive_coordinator_test.dart
```

Expected: all tests pass, including the new race and multi-lease guards.

### Task 3: Verify lifecycle coverage and repository gates

**Files:**
- Modify: `docs/superpowers/plans/2026-07-30-production-pipeline-archive-gate.md`

- [x] **Step 1: Format only owned Dart files**

Run:

```bash
dart format lib/official_capture/photo_archive_coordinator.dart test/photo_archive_coordinator_test.dart test/database_archive_coordinator_test.dart
```

Expected: only these three Dart files are formatted.

- [x] **Step 2: Run archive lifecycle contracts**

Run:

```bash
flutter test test/photo_archive_lifecycle_contract_test.dart test/database_archive_lifecycle_contract_test.dart test/archive_background_runtime_test.dart
```

Expected: capture, live reconstruction, resume, and background wake-up remain
wired to the shared coordinator.

- [x] **Step 3: Run project validation**

Run:

```bash
flutter analyze lib/ test/
flutter test
```

Expected: analyzer remains at exactly the known 12 legacy issues with no new
issue, and the complete test suite passes.

- [ ] **Step 4: Inspect and stage only owned files**

Run:

```bash
git diff -- lib/official_capture/photo_archive_coordinator.dart test/photo_archive_coordinator_test.dart test/database_archive_coordinator_test.dart docs/superpowers/plans/2026-07-30-production-pipeline-archive-gate.md
git add lib/official_capture/photo_archive_coordinator.dart test/photo_archive_coordinator_test.dart test/database_archive_coordinator_test.dart docs/superpowers/plans/2026-07-30-production-pipeline-archive-gate.md
git diff --cached --check
```

Expected: the index contains only the four listed files and no whitespace
errors.
