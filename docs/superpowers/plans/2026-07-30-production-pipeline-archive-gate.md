# Production Pipeline Archive Gate and Immediate Preemption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Per the user's explicit instruction, this plan is executed inline by the primary agent without subagents.

**Goal:** Guarantee that JPEG XL and ZPAQ cold archival runs only while every
official production pipeline is idle, immediately requests cancellation of
in-flight archive work when capture or reconstruction starts, and automatically
resumes from source-safe state after the final production activity ends.

**Architecture:** `PhotoArchiveCoordinator` remains the single portable Dart
owner of compression scheduling. Capture and reconstruction keep using reference
counted production leases; acquiring any lease closes the gate and requests
cooperative cancellation from both photo and database codecs. JPEG XL gains the
same generation-based native cancellation contract already used by ZPAQ, so a
cancelled transaction deletes only temporary outputs, retains the source, and
retries after the final lease closes.

**Tech Stack:** Dart, Flutter test, Objective-C++, C ABI, pinned portable
libjxl/libzpaq, existing append-only archive audit store.

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

### Task 4: Upgrade the photo transaction contract from boundary pause to cancellation

**Files:**
- Modify: `lib/official_capture/photo_archive_codec.dart`
- Modify: `lib/official_capture/photo_archive_transaction.dart`
- Modify: `lib/official_capture/photo_archive_coordinator.dart`
- Modify: `test/photo_archive_transaction_test.dart`
- Modify: `test/photo_archive_coordinator_test.dart`
- Modify: every test double implementing `PhotoArchiveCodec`

- [x] **Step 1: Write the transaction cancellation regression**

Add a codec that writes a temporary byte and throws the typed cancellation:

```dart
final class _CancelledPhotoCodec extends _ZlibTestCodec {
  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    await destinationJxl.writeAsBytes(const <int>[1], flush: true);
    throw const PhotoArchiveCancelled();
  }
}
```

The test SHALL require `paused == true`, an empty `failedNames`, the exact
source bytes still present, and both `.jxl.tmp` and `.verify.tmp` absent.

- [x] **Step 2: Write the coordinator cancellation/release race**

Use a blocking photo codec whose `requestCancellation()` completes the blocked
first encode with `PhotoArchiveCancelled`. Start archival, acquire and
immediately release a capture lease, and require one cancellation request, two
encode attempts, a committed exact archive, and no source JPEG after automatic
resume.

- [x] **Step 3: Run the focused tests and verify RED**

Run:

```bash
flutter test --no-pub \
  test/photo_archive_transaction_test.dart \
  test/photo_archive_coordinator_test.dart
```

Expected: compilation fails because `PhotoArchiveCodec.requestCancellation`
and `PhotoArchiveCancelled` do not exist.

- [x] **Step 4: Add the portable cancellation contract**

`PhotoArchiveCodec` SHALL expose:

```dart
void requestCancellation();
```

and `photo_archive_codec.dart` SHALL define:

```dart
final class PhotoArchiveCancelled implements Exception {
  const PhotoArchiveCancelled();
}
```

Test codecs that execute synchronously use an empty cancellation method.

- [x] **Step 5: Treat cancellation as a pause, never a failure**

In `PhotoArchiveTransaction.archiveCapture`, catch
`PhotoArchiveCancelled` before the general catch, delete both temporary files,
set `paused = true`, and stop the capture loop. Do not publish an archive,
manifest entry, failed filename, or source deletion.

- [x] **Step 6: Close the gate by cancelling both codecs**

Both `_beginProductionActivity` and `requestSystemInterruption` SHALL invoke:

```dart
codec.requestCancellation();
databaseCodec?.requestCancellation();
```

The queue loop and per-file checks remain as backstops. The final production
lease release waits for the cancelled pump to reach source-safe state, then
automatically retries pending work.

- [x] **Step 7: Run the focused tests and verify GREEN**

Run the Step 3 command. Expected: all photo transaction/coordinator tests pass.

### Task 5: Make the pinned JPEG XL bridge cooperatively cancellable

**Files:**
- Modify: `ios/Runner/pw_jxl_bridge.h`
- Modify: `ios/Runner/pw_jxl_bridge.mm`
- Modify: `lib/official_capture/photo_archive_ffi_codec.dart`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Modify: `ios/RunnerTests/PWJXLBridgeTests.mm`
- Modify: `test/photo_archive_ffi_contract_test.dart`

- [x] **Step 1: Lock the additive C ABI in a failing contract test**

Require these retained symbols in the header, Dart FFI bindings, and every
Runner linker configuration:

```text
pw_jxl_cancellation_generation
pw_jxl_request_cancel
pw_jxl_encode_jpeg_file_cancellable
pw_jxl_reconstruct_jpeg_file_cancellable
```

Also require `PW_JXL_CANCELLED` and Dart mapping to
`PhotoArchiveCancelled`.

- [x] **Step 2: Add generation-based cancellation state**

The bridge SHALL own a process-global `std::atomic<uint64_t>` generation.
Each cancellable operation receives the generation observed at its start.
`pw_jxl_request_cancel()` increments the generation; a mismatch returns
`PW_JXL_CANCELLED`.

- [x] **Step 3: Add a cancellable parallel runner**

Wrap the pinned libjxl parallel runner so every dispatched libjxl work item
checks the operation generation before entering the work callback. A mismatch
skips remaining callbacks and makes the runner return
`JXL_PARALLEL_RET_RUNNER_ERROR`; the bridge translates a concurrent generation
change to `PW_JXL_CANCELLED`, not a generic encoder error. Check the generation
before and after file I/O and each encoder/decoder processing step as well.

- [x] **Step 4: Keep the existing ABI and add cancellable entry points**

Existing non-cancellable functions remain available for native compatibility.
The new functions accept the starting cancellation generation and use the
cancellable runner. No archive format, effort, pinned revision, or
byte-reconstruction rule changes.

- [x] **Step 5: Wire Dart to the cancellable ABI**

`JxlFfiPhotoArchiveCodec` reads the current generation before each isolate
operation, calls the new entry point, maps `PW_JXL_CANCELLED` to
`PhotoArchiveCancelled`, and implements `requestCancellation()` by calling
`pw_jxl_request_cancel()`.

- [x] **Step 6: Verify the bridge and FFI contract**

Run:

```bash
flutter test --no-pub test/photo_archive_ffi_contract_test.dart
```

Then run the existing native bridge test target through the pinned Xcode
configuration. Expected: legacy byte-exact roundtrip still passes and a stale
generation is rejected as cancellation.

Verification deviation: the complete Runner XCTest build was blocked before
the test target by the existing `thermion_dart` simulator native-asset hook.
The bridge instead passed `clang++ -Wall -Wextra -Werror` for the simulator,
the Dart ABI contract, an isolated simulator app using the same pinned
libraries (normal exact roundtrip, stale-generation rejection, and 12MP
mid-flight cancellation), and an unsigned iPhoneOS release build. The 12MP
simulator operation stopped 83 ms after cancellation, retained its source, and
left no archive output.

### Task 6: Remove every production-start wait on cold compression

**Files:**
- Modify: `lib/official_capture/capture_session.dart`
- Modify: `lib/official_capture/sfm_resume.dart`
- Modify: `test/database_archive_lifecycle_contract_test.dart`
- Modify: `test/photo_archive_lifecycle_contract_test.dart`

- [x] **Step 1: Require immediate capture and resume ownership**

Lifecycle contracts SHALL require both entry points to acquire a production
lease and SHALL reject `await photoArchiveCoordinator.waitForIdle()` in either
entry point.

- [x] **Step 2: Remove the two waits**

Capture and reconstruction recovery continue immediately after acquiring their
leases. Codec cancellation and source-safe temporary cleanup happen
asynchronously in the archive pump; foreground work never waits for old cold
maintenance.

- [x] **Step 3: Verify lifecycle wiring**

Run:

```bash
flutter test --no-pub \
  test/photo_archive_lifecycle_contract_test.dart \
  test/database_archive_lifecycle_contract_test.dart \
  test/archive_background_runtime_test.dart
```

Expected: capture, live reconstruction, resumed reconstruction, background
wake-up, interruption, and final-lease auto-resume all remain wired.

### Task 7: Update accepted behavior and verify the production boundary

**Files:**
- Modify: `openspec/changes/add-future-jxl-photo-archive/specs/future-photo-archive/spec.md`
- Modify: `openspec/changes/add-future-jxl-photo-archive/tasks.md`
- Modify: `openspec/changes/add-official-archive-background-processing/design.md`
- Modify: `openspec/changes/add-official-archive-background-processing/specs/official-archive-background-processing/spec.md`

- [x] **Step 1: Replace file-boundary language**

The specifications SHALL state that any production lease requests cancellation
of in-flight JXL and ZPAQ work; uncommitted temporary files are removed,
authoritative sources remain, and work resumes only after the final production
lease closes. “Finish the current JPEG” is no longer permitted behavior.

- [x] **Step 2: Run deterministic repository gates**

Run:

```bash
dart format \
  lib/official_capture/photo_archive_codec.dart \
  lib/official_capture/photo_archive_ffi_codec.dart \
  lib/official_capture/photo_archive_coordinator.dart \
  lib/official_capture/photo_archive_transaction.dart \
  lib/official_capture/capture_session.dart \
  lib/official_capture/sfm_resume.dart \
  test/photo_archive_transaction_test.dart \
  test/photo_archive_coordinator_test.dart
flutter analyze --no-pub \
  lib/official_capture/photo_archive_codec.dart \
  lib/official_capture/photo_archive_ffi_codec.dart \
  lib/official_capture/photo_archive_coordinator.dart \
  lib/official_capture/photo_archive_transaction.dart \
  lib/official_capture/capture_session.dart \
  lib/official_capture/sfm_resume.dart
openspec validate add-future-jxl-photo-archive --strict
openspec validate add-official-archive-background-processing --strict
git diff --check
```

Expected: formatting is stable, analyzer reports no new issue, both OpenSpec
changes validate, and the focused diff has no whitespace error.

Result (2026-07-31): the focused analyzer reported no issues; both strict
OpenSpec validations, `git diff --check`, and the Objective-C++ bridge syntax
check passed. The complete Flutter suite passed all 418 tests. Full-repository
analysis still reports 17 pre-existing warnings outside this change and no
error.

- [ ] **Step 3: Perform physical-phone production validation**

Use only the repository's container-preserving in-place update runbook. After
verified Documents/Library backup and a signed marked build, start cold photo
compression, enter capture during an in-flight JPEG, and require:

- capture readiness does not wait for the old archive file;
- the audit records an intentional pause rather than a retry failure;
- no archive CPU/GPU work continues while capture/reconstruction leases exist;
- the source JPEG and project data remain byte-identical;
- compression automatically resumes after reconstruction releases the final
  lease.

Production-device status (2026-07-31): signed build `2026073102` was installed
in place with marker `production-archive-hard-stop-v1`; the app-tree SHA-256 is
`93fcf866512aea81c7560e8315bb0dade67ac850a8c35d77f80cfa8f9cbf7abb`.
The pre-update backup and post-update readback verified all 1,457 Documents
files and all 26 non-SplashBoard Library files byte-for-byte, with zero added
paths; eight rotating SplashBoard snapshot files were excluded by policy. The
new build's cold archive recorded `scan_started` and `capture_started` at
12:35 local time. This step remains unchecked until a user enters capture or
reconstruction during that in-flight work and the subsequent
`capture_paused` plus final-lease auto-resume events are collected.
