# Future Official ZPAQ Database Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically replace only future official projects'
`official_sfm_live.db` with a smaller ZPAQ 7.15 method-5 archive after proving
that decompression restores the exact original bytes.

**Architecture:** Independent database policy/manifest/transaction/resolver
modules plug into the existing official JPEG XL cold coordinator. Dart owns all
eligibility, SHA-256, atomic state, scheduling, and recovery decisions; pinned
portable libzpaq C++ exposes a file-oriented C ABI and runs from a background
Dart isolate. The retired self-developed pipeline is not modified.

**Tech Stack:** Flutter 3.41.8, Dart 3.11.5, `dart:io`,
`package:crypto`, `dart:ffi`, official libzpaq 7.15, C++17/NOJIT, Flutter test,
XCTest, OpenSpec.

---

## File map

**Create**

- `lib/official_capture/database_archive_codec.dart`: platform-neutral
  compress/decompress/cancel interface.
- `lib/official_capture/database_archive_ffi_codec.dart`: iOS dynamic-symbol
  binding and background-isolate execution.
- `lib/official_capture/database_archive_policy.dart`: independent
  creation-time eligibility marker.
- `lib/official_capture/database_archive_manifest.dart`: one fixed database
  entry with exact hashes and codec identity.
- `lib/official_capture/database_archive_transaction.dart`: source-last
  archive/reconciliation transaction.
- `lib/official_capture/database_archive_resolver.dart`: raw-first
  recoverability check and verified atomic restore.
- `test/database_archive_policy_test.dart`
- `test/database_archive_transaction_test.dart`
- `test/database_archive_resolver_test.dart`
- `test/database_archive_coordinator_test.dart`
- `test/database_archive_lifecycle_contract_test.dart`
- `test/database_archive_ffi_contract_test.dart`
- `ios/Runner/pw_zpaq_bridge.h`
- `ios/Runner/pw_zpaq_bridge.cpp`
- `ios/RunnerTests/PWZpaqBridgeTests.mm`
- `ios/Vendor/Zpaq/include/libzpaq.h`
- `ios/Vendor/Zpaq/src/libzpaq.cpp`
- `ios/Vendor/Zpaq/Zpaq-LICENSE.txt`
- `ios/Vendor/Zpaq/REVISION`
- `ios/Vendor/Zpaq/SHA256SUMS`

**Modify**

- `lib/official_capture/capture_session.dart`: write the new marker before
  publishing a new official capture; wait for cancelling cold work at capture
  start.
- `lib/official_capture/photo_archive_coordinator.dart`: sequence the
  independent database transaction and expose cancellation/idle waiting.
- `lib/official_capture/photo_archive_runtime.dart`: install the production
  ZPAQ codec.
- `lib/official_capture/sfm_resume.dart`: recognize archive-only official
  projects and materialize before official SfM starts.
- `lib/ui/me_page.dart`: route official recoverability checks through the
  archive-aware official resolver.
- `ios/Runner.xcodeproj/project.pbxproj`: compile bridge/libzpaq/tests, include
  headers/license, and retain C symbols.
- `ios/Runner/Info.plist`: add the explicit ZPAQ production marker.
- `pubspec.yaml`: ship the ZPAQ license as a Flutter asset.
- `THIRD_PARTY_NOTICES`: record source, exact revision hash, license, and use.
- `openspec/changes/add-future-official-zpaq-database-archive/tasks.md`: check
  items only after their acceptance commands pass.

**Explicitly do not modify**

- `lib/official_capture/sfm_live_recon.dart` (shared dirty file and unnecessary
  for this design).
- Any file under `lib/capture/`, any `captures/` behavior, or `sfm_live.db`.
- Existing/historical project contents.

## Task 1: Future-only policy and fixed manifest

**Files:**

- Create: `test/database_archive_policy_test.dart`
- Create: `lib/official_capture/database_archive_policy.dart`
- Create: `lib/official_capture/database_archive_manifest.dart`

- [ ] **Step 1: Write the failing policy/manifest tests**

```dart
test('writes and reloads the exact future official policy', () async {
  final policy = await DatabaseArchivePolicy.writeForNewCapture(capture);
  expect(policy.schema, DatabaseArchivePolicy.schemaV1);
  expect(policy.sourceFile, DatabaseArchivePolicy.sourceFileName);
  expect(policy.codec, 'zpaq');
  expect(policy.version, '7.15');
  expect(policy.method, 5);
  expect(policy.revision, DatabaseArchivePolicy.pinnedRevision);
  expect(await DatabaseArchivePolicy.readCompatible(capture), isNotNull);
});

test('missing malformed and incompatible markers are ineligible', () async {
  expect(await DatabaseArchivePolicy.readCompatible(capture), isNull);
  final marker =
      File('${capture.path}/${DatabaseArchivePolicy.fileName}');
  await marker.writeAsString('{');
  expect(await DatabaseArchivePolicy.readCompatible(capture), isNull);
  await marker.writeAsString(jsonEncode(<String, Object?>{
    'schema': DatabaseArchivePolicy.schemaV1,
    'source_file': DatabaseArchivePolicy.sourceFileName,
    'codec': 'zpaq',
    'version': '7.15',
    'revision': DatabaseArchivePolicy.pinnedRevision,
    'method': 4,
    'created_at': DateTime.now().toUtc().toIso8601String(),
  }));
  expect(await DatabaseArchivePolicy.readCompatible(capture), isNull);
});

test('manifest rejects changed paths and hashes', () async {
  final manifest = DatabaseArchiveManifest(
    sourceBytes: 10,
    sourceSha256:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    archiveBytes: 5,
    archiveSha256:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    verifiedAt: DateTime.utc(2026).toIso8601String(),
  );
  await manifest.writeAtomic(capture);
  expect(await DatabaseArchiveManifest.read(capture), isNotNull);
  final file =
      File('${capture.path}/${DatabaseArchiveManifest.fileName}');
  final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  json['archive_file'] = '../outside.zpaq';
  await file.writeAsString(jsonEncode(json));
  expect(await DatabaseArchiveManifest.read(capture), isNull);
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
flutter test test/database_archive_policy_test.dart
```

Expected: compilation fails because `DatabaseArchivePolicy` and
`DatabaseArchiveManifest` do not exist.

- [ ] **Step 3: Implement the minimal policy and manifest**

Use these exact identities:

```dart
static const fileName = 'official_database_archive_policy.json';
static const schemaV1 = 'pw_official_database_archive_policy_v1';
static const sourceFileName = 'official_sfm_live.db';
static const codecName = 'zpaq';
static const version715 = '7.15';
static const method5 = 5;
static const pinnedRevision =
    'e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418';
```

The manifest uses only:

```dart
static const fileName = 'official_database_archive.json';
static const schemaV1 = 'pw_official_database_archive_manifest_v1';
static const archiveFileName = 'official_sfm_live.db.zpaq';
```

Both writers serialize to `<canonical>.tmp` with `flush: true` and rename only
after encoding succeeds. Readers return `null` on missing files, malformed JSON,
unknown identity fields, negative lengths, non-64-character lowercase hex
digests, unsafe paths, `FileSystemException`, `FormatException`, or `TypeError`.

- [ ] **Step 4: Run the focused test and verify GREEN**

```bash
flutter test test/database_archive_policy_test.dart
```

Expected: all policy and manifest tests pass.

- [ ] **Step 5: Commit only Task 1 files**

```bash
git add -- test/database_archive_policy_test.dart \
  lib/official_capture/database_archive_policy.dart \
  lib/official_capture/database_archive_manifest.dart
git commit -m "feat(archive): gate future official databases"
```

## Task 2: Byte-exact source-last transaction

**Files:**

- Create: `test/database_archive_transaction_test.dart`
- Create: `lib/official_capture/database_archive_codec.dart`
- Create: `lib/official_capture/database_archive_transaction.dart`

- [ ] **Step 1: Write the failing transaction tests**

Define a deterministic zlib-backed fake implementing:

```dart
abstract interface class DatabaseArchiveCodec {
  bool get isSupported;
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  });
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  });
  void requestCancellation();
}

final class DatabaseArchiveCancelled implements Exception {
  const DatabaseArchiveCancelled();
}
```

Use one fixture helper that writes the policy, non-empty final artifacts, and
raw database before calling the transaction:

```dart
Future<File> writeReadyDatabase(List<int> bytes) async {
  await DatabaseArchivePolicy.writeForNewCapture(capture);
  await File('${capture.path}/official_sfm_sparse.ply')
      .writeAsBytes(<int>[1], flush: true);
  await File('${capture.path}/official_sfm_sparse_meta.json')
      .writeAsString('{"n_points":1}', flush: true);
  final source = File('${capture.path}/official_sfm_live.db');
  await source.writeAsBytes(bytes, flush: true);
  return source;
}

test('commits smaller exact archive before deleting source', () async {
  final original = List<int>.filled(8192, 42);
  final source = await writeReadyDatabase(original);
  final result = await DatabaseArchiveTransaction(
    codec: ZlibDatabaseCodec(),
  ).archiveCapture(capture);
  expect(result.archived, isTrue);
  expect(await source.exists(), isFalse);
  expect(await File('${source.path}.zpaq').exists(), isTrue);
  expect((await DatabaseArchiveManifest.read(capture))!.sourceBytes,
      original.length);
});

test('byte mismatch retains source and publishes no manifest', () async {
  final source = await writeReadyDatabase(List<int>.filled(4096, 7));
  final result = await DatabaseArchiveTransaction(
    codec: MismatchingDatabaseCodec(),
  ).archiveCapture(capture);
  expect(result.failed, isTrue);
  expect(await source.exists(), isTrue);
  expect(await DatabaseArchiveManifest.read(capture), isNull);
});

test('codec failure retains source and remains retryable', () async {
  final source = await writeReadyDatabase(List<int>.filled(4096, 8));
  final result = await DatabaseArchiveTransaction(
    codec: FailingDatabaseCodec(),
  ).archiveCapture(capture);
  expect(result.failed, isTrue);
  expect(await source.exists(), isTrue);
  expect(await File('${source.path}.zpaq.tmp').exists(), isFalse);
});

test('non-smaller exact archive keeps the database', () async {
  final source = await writeReadyDatabase(
    List<int>.generate(256, (index) => index),
  );
  final result = await DatabaseArchiveTransaction(
    codec: LargerExactDatabaseCodec(),
  ).archiveCapture(capture);
  expect(result.skipped, isTrue);
  expect(await source.exists(), isTrue);
  expect(await File('${source.path}.zpaq').exists(), isFalse);
});

test('SQLite sidecar postpones archive without invoking codec', () async {
  final source = await writeReadyDatabase(List<int>.filled(4096, 9));
  await File('${source.path}-wal').writeAsBytes(<int>[1], flush: true);
  final codec = CountingDatabaseCodec();
  final result = await DatabaseArchiveTransaction(
    codec: codec,
  ).archiveCapture(capture);
  expect(result.skipped, isTrue);
  expect(codec.compressCalls, 0);
  expect(await source.exists(), isTrue);
});

test('continuation gate interruption retains the source', () async {
  final source = await writeReadyDatabase(List<int>.filled(4096, 10));
  var checks = 0;
  final result = await DatabaseArchiveTransaction(
    codec: ZlibDatabaseCodec(),
    canContinue: () => ++checks < 2,
  ).archiveCapture(capture);
  expect(result.interrupted, isTrue);
  expect(await source.exists(), isTrue);
  expect(await DatabaseArchiveManifest.read(capture), isNull);
});

test('restart reconciles crash after manifest commit', () async {
  final source = await writeReadyDatabase(List<int>.filled(8192, 11));
  final first = await DatabaseArchiveTransaction(
    codec: ZlibDatabaseCodec(),
    afterManifestCommitted: (_) async => throw StateError('process stop'),
  ).archiveCapture(capture);
  expect(first.failed, isTrue);
  expect(await source.exists(), isTrue);
  expect(await DatabaseArchiveManifest.read(capture), isNotNull);
  final second = await DatabaseArchiveTransaction(
    codec: ZlibDatabaseCodec(),
  ).archiveCapture(capture);
  expect(second.archived, isTrue);
  expect(await source.exists(), isFalse);
});

test('changed restored database replaces stale archive safely', () async {
  final source = await writeReadyDatabase(List<int>.filled(8192, 12));
  await DatabaseArchiveTransaction(
    codec: ZlibDatabaseCodec(),
  ).archiveCapture(capture);
  await source.writeAsBytes(List<int>.filled(8192, 13), flush: true);
  final result = await DatabaseArchiveTransaction(
    codec: ZlibDatabaseCodec(),
  ).archiveCapture(capture);
  expect(result.archived, isTrue);
  final restored = File('${capture.path}/changed-restored.db');
  await ZlibDatabaseCodec().decompress(
    sourceArchive: File('${source.path}.zpaq'),
    destinationDatabase: restored,
  );
  expect(await restored.readAsBytes(), List<int>.filled(8192, 13));
});
```

Every fixture writes non-empty `official_sfm_sparse.ply` and
`official_sfm_sparse_meta.json`, an independent database policy, and a raw
database. Assert exact restored bytes, source/archive hashes, temporary-file
cleanup, and source-last ordering through an `afterManifestCommitted` hook.

- [ ] **Step 2: Run the focused test and verify RED**

```bash
flutter test test/database_archive_transaction_test.dart
```

Expected: compilation fails because the codec and transaction types do not
exist.

- [ ] **Step 3: Implement the minimal transaction**

The public contract is:

```dart
typedef DatabaseArchiveCommitHook = Future<void> Function(File sourceDatabase);
typedef DatabaseArchiveContinueCheck = FutureOr<bool> Function();

class DatabaseArchiveRunResult {
  const DatabaseArchiveRunResult({
    this.eligible = true,
    this.archived = false,
    this.skipped = false,
    this.failed = false,
    this.interrupted = false,
  });
  final bool eligible;
  final bool archived;
  final bool skipped;
  final bool failed;
  final bool interrupted;
}

class DatabaseArchiveTransaction {
  const DatabaseArchiveTransaction({
    required this.codec,
    this.afterManifestCommitted,
    this.canContinue,
  });

  Future<DatabaseArchiveRunResult> archiveCapture(
    Directory captureDirectory,
  );
}
```

The method performs this exact order:

```text
compatible policy
-> non-empty PLY/meta
-> no -wal/-shm/-journal
-> clean fixed .tmp files
-> reconcile a matching committed duplicate
-> source SHA-256/length
-> canContinue
-> codec.compress(.zpaq.tmp)
-> canContinue
-> codec.decompress(.verify.tmp)
-> length + SHA-256 + streaming byte equality
-> archive strictly smaller
-> canContinue
-> replace canonical .zpaq
-> atomic manifest
-> afterManifestCommitted hook
-> source delete
-> verify-temp delete
```

Catch `DatabaseArchiveCancelled` separately and return `interrupted: true`.
Other exceptions return `failed: true`. Both paths delete fixed temporaries and
retain the raw source. A stale archive/manifest with a changed raw SHA-256 is
safe to replace because the raw source stays until the new manifest commits.

- [ ] **Step 4: Run the focused tests and verify GREEN**

```bash
flutter test test/database_archive_policy_test.dart \
  test/database_archive_transaction_test.dart
```

Expected: all tests pass with no temporary files left behind.

- [ ] **Step 5: Commit only Task 2 files**

```bash
git add -- test/database_archive_transaction_test.dart \
  lib/official_capture/database_archive_codec.dart \
  lib/official_capture/database_archive_transaction.dart
git commit -m "feat(archive): verify ZPAQ database transactions"
```

## Task 3: Verified raw-first recovery

**Files:**

- Create: `test/database_archive_resolver_test.dart`
- Create: `lib/official_capture/database_archive_resolver.dart`

- [ ] **Step 1: Write failing resolver tests**

```dart
Future<void> createArchiveOnlyFixture(
  Directory capture,
  DatabaseArchiveCodec codec,
  List<int> original,
) async {
  await DatabaseArchivePolicy.writeForNewCapture(capture);
  await File('${capture.path}/official_sfm_sparse.ply')
      .writeAsBytes(<int>[1], flush: true);
  await File('${capture.path}/official_sfm_sparse_meta.json')
      .writeAsString('{"n_points":1}', flush: true);
  final raw = File('${capture.path}/official_sfm_live.db');
  await raw.writeAsBytes(original, flush: true);
  final result = await DatabaseArchiveTransaction(
    codec: codec,
  ).archiveCapture(capture);
  expect(result.archived, isTrue);
  expect(await raw.exists(), isFalse);
}

test('raw historical database is recoverable without a marker', () async {
  final raw = File('${capture.path}/official_sfm_live.db');
  await raw.writeAsBytes(<int>[1, 2, 3], flush: true);
  final resolver = DatabaseArchiveResolver(codec: codec);
  expect(await resolver.isRecoverable(capture), isTrue);
  expect(await resolver.resolveDatabase(capture), raw);
});

test('valid archive-only project restores exact raw bytes', () async {
  await DatabaseArchivePolicy.writeForNewCapture(capture);
  await File('${capture.path}/official_sfm_sparse.ply')
      .writeAsBytes(<int>[1], flush: true);
  await File('${capture.path}/official_sfm_sparse_meta.json')
      .writeAsString('{"n_points":1}', flush: true);
  final raw = File('${capture.path}/official_sfm_live.db');
  await raw.writeAsBytes(original, flush: true);
  await DatabaseArchiveTransaction(codec: codec).archiveCapture(capture);
  final resolver = DatabaseArchiveResolver(codec: codec);
  expect(await resolver.isRecoverable(capture), isTrue);
  final restored = await resolver.resolveDatabase(capture);
  expect(await restored!.readAsBytes(), original);
  expect(await File('${raw.path}.zpaq').exists(), isTrue);
});

test('corrupt archive is neither recoverable nor materialized', () async {
  await createArchiveOnlyFixture(capture, codec, original);
  final archive = File('${capture.path}/official_sfm_live.db.zpaq');
  final bytes = await archive.readAsBytes();
  bytes[bytes.length - 1] ^= 1;
  await archive.writeAsBytes(bytes, flush: true);
  final resolver = DatabaseArchiveResolver(codec: codec);
  expect(await resolver.isRecoverable(capture), isFalse);
  expect(await resolver.resolveDatabase(capture), isNull);
  expect(
    await File('${capture.path}/official_sfm_live.db').exists(),
    isFalse,
  );
});

test('wrong decompressed SHA leaves no raw or temporary database', () async {
  await createArchiveOnlyFixture(capture, codec, original);
  final resolver = DatabaseArchiveResolver(
    codec: MismatchingDatabaseCodec(),
  );
  expect(await resolver.resolveDatabase(capture), isNull);
  expect(
    await File('${capture.path}/official_sfm_live.db').exists(),
    isFalse,
  );
  expect(
    await File('${capture.path}/official_sfm_live.db.verify.tmp').exists(),
    isFalse,
  );
});
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
flutter test test/database_archive_resolver_test.dart
```

Expected: compilation fails because `DatabaseArchiveResolver` does not exist.

- [ ] **Step 3: Implement the resolver**

```dart
class DatabaseArchiveResolver {
  const DatabaseArchiveResolver({required this.codec});
  final DatabaseArchiveCodec codec;

  Future<bool> isRecoverable(Directory captureDirectory);
  Future<File?> resolveDatabase(Directory captureDirectory);
}
```

`isRecoverable` returns true immediately for an existing raw database.
Archive-only checks require compatible policy/manifest, codec support, and the
canonical archive's declared length/SHA-256; it does not decompress during UI
discovery. `resolveDatabase` repeats those checks, decompresses to
`official_sfm_live.db.verify.tmp`, verifies original length/SHA-256, and renames
to `official_sfm_live.db`. It retains the canonical archive and deletes a failed
temporary.

- [ ] **Step 4: Run the focused tests and verify GREEN**

```bash
flutter test test/database_archive_resolver_test.dart \
  test/database_archive_transaction_test.dart
```

Expected: all recovery and transaction tests pass.

- [ ] **Step 5: Commit only Task 3 files**

```bash
git add -- test/database_archive_resolver_test.dart \
  lib/official_capture/database_archive_resolver.dart
git commit -m "feat(archive): restore verified official databases"
```

## Task 4: Connect only the official lifecycle

**Files:**

- Create: `test/database_archive_coordinator_test.dart`
- Create: `test/database_archive_lifecycle_contract_test.dart`
- Modify: `lib/official_capture/capture_session.dart`
- Modify: `lib/official_capture/photo_archive_coordinator.dart`
- Modify: `lib/official_capture/photo_archive_runtime.dart`
- Modify: `lib/official_capture/sfm_resume.dart`
- Modify: `lib/ui/me_page.dart`

- [ ] **Step 1: Write failing coordinator and source-contract tests**

Coordinator tests use a recording database codec and prove:

```dart
test('photo-only historical marker never archives the database', () async {
  final capture = await createReadyCapture(
    'photo-only',
    photoMarked: true,
    databaseMarked: false,
  );
  final database = RecordingDatabaseCodec();
  final coordinator = PhotoArchiveCoordinator(
    codec: ZlibPhotoCodec(),
    databaseCodec: database,
  );
  await coordinator.discoverUnderDocuments(documents);
  expect(database.compressCalls, 0);
  expect(
    await File('${capture.path}/official_sfm_live.db').exists(),
    isTrue,
  );
});

test('database transaction runs after photo archive work', () async {
  final order = <String>[];
  final capture = await createReadyCapture(
    'ordered',
    photoMarked: true,
    databaseMarked: true,
  );
  final coordinator = PhotoArchiveCoordinator(
    codec: ZlibPhotoCodec(onEncode: () => order.add('photo')),
    databaseCodec: RecordingDatabaseCodec(
      onCompress: () => order.add('database'),
    ),
  );
  await coordinator.noteArtifactsPersisted(capture);
  expect(order, <String>['photo', 'database']);
});

test('foreground activity requests cancellation and waits for idle', () async {
  final database = BlockingDatabaseCodec();
  final capture = await createReadyCapture(
    'cancel',
    photoMarked: false,
    databaseMarked: true,
  );
  final coordinator = PhotoArchiveCoordinator(
    codec: ZlibPhotoCodec(),
    databaseCodec: database,
  );
  final archiveFuture = coordinator.noteArtifactsPersisted(capture);
  await database.started.future;
  final lease = coordinator.beginCaptureActivity();
  expect(database.cancellationRequested, isTrue);
  database.failCancelled();
  await coordinator.waitForIdle();
  await archiveFuture;
  expect(
    await File('${capture.path}/official_sfm_live.db').exists(),
    isTrue,
  );
  await lease.close();
});

test('startup discovers an independent database marker', () async {
  final capture = await createReadyCapture(
    'database-only',
    photoMarked: false,
    databaseMarked: true,
  );
  final coordinator = PhotoArchiveCoordinator(
    codec: ZlibPhotoCodec(),
    databaseCodec: RecordingDatabaseCodec(),
  );
  await coordinator.discoverUnderDocuments(documents);
  expect(
    await File('${capture.path}/official_sfm_live.db.zpaq').exists(),
    isTrue,
  );
});
```

Source-contract tests assert:

```dart
expect(captureSession, contains(
  'DatabaseArchivePolicy.writeForNewCapture(root)',
));
expect(captureSession, contains(
  'await photoArchiveCoordinator.waitForIdle()',
));
expect(runtime, contains('ZpaqFfiDatabaseArchiveCodec'));
expect(resume, contains('DatabaseArchiveResolver'));
expect(resume, contains('await photoArchiveCoordinator.waitForIdle()'));
expect(mePage, contains(
  'official_sfm_resume.resolveRecoverableCaptureDir',
));
expect(selfCaptureFiles, isNot(contains('DatabaseArchive')));
```

- [ ] **Step 2: Run and verify RED**

```bash
flutter test test/database_archive_coordinator_test.dart \
  test/database_archive_lifecycle_contract_test.dart
```

Expected: missing constructor arguments, marker calls, resolver calls, and idle
waiting make the new expectations fail.

- [ ] **Step 3: Implement coordinator/runtime/capture integration**

Keep the existing constructor parameter `codec` for JPEG XL compatibility and
add:

```dart
PhotoArchiveCoordinator({
  required this.codec,
  this.databaseCodec,
});

final DatabaseArchiveCodec? databaseCodec;

Future<void> waitForIdle() async {
  final active = _pumpFuture;
  if (active != null) await active;
}
```

Both activity-acquisition methods increment the existing gate and call
`databaseCodec?.requestCancellation()`. Discovery enqueues when either the photo
or database policy is compatible. `_isDurablyReady` accepts either marker but
still requires the existing bundle, PLY, and metadata. `_runPump` preserves
preview/JPEG behavior, then runs:

```dart
final database = databaseCodec;
if (database != null && _foregroundActivityCount == 0) {
  final result = await DatabaseArchiveTransaction(
    codec: database,
    canContinue: () => _foregroundActivityCount == 0,
  ).archiveCapture(item.value);
  if (result.interrupted || _foregroundActivityCount != 0) {
    _pending[item.key] = item.value;
    return;
  }
}
```

`photo_archive_runtime.dart` passes
`databaseCodec: ZpaqFfiDatabaseArchiveCodec()`.

In `CaptureSession.start`, acquire the existing lease and immediately await
`photoArchiveCoordinator.waitForIdle()` before camera/capture setup continues.
In `_setupPhotosDirectory`, write `DatabaseArchivePolicy` immediately after
`PhotoArchivePolicy` and before `_captureDir = root.path`.

- [ ] **Step 4: Implement official recovery integration**

`official_capture/sfm_resume.dart` owns the public official lookup:

```dart
Future<String?> resolveRecoverableCaptureDir(String recordCaptureDir) async {
  if (recordCaptureDir.isEmpty) return null;
  final resolver = DatabaseArchiveResolver(codec: databaseArchiveCodec);
  final direct = Directory(recordCaptureDir);
  if (await resolver.isRecoverable(direct)) return direct.path;
  final docs = (await getApplicationDocumentsDirectory()).path;
  final rebuilt = Directory(
    '$docs/captures_official/${recordCaptureDir.split('/').last}',
  );
  return await resolver.isRecoverable(rebuilt) ? rebuilt.path : null;
}
```

At `_resumeOne` entry, acquire an outer existing archive reconstruction lease,
wait for idle cancellation, and call `resolveDatabase` before
`SfmLiveRecon.start`. Close the outer lease in `finally` after recon disposal.
Use the same resolver inside the explicit sweep.

Import official resume in `me_page.dart` with a prefix and delegate official
lookups to the public function; retain the self pipeline's existing resolver
unchanged.

- [ ] **Step 5: Run all Dart archive tests and commit exact files**

```bash
flutter test test/database_archive_policy_test.dart \
  test/database_archive_transaction_test.dart \
  test/database_archive_resolver_test.dart \
  test/database_archive_coordinator_test.dart \
  test/database_archive_lifecycle_contract_test.dart \
  test/photo_archive_coordinator_test.dart \
  test/photo_archive_lifecycle_contract_test.dart
```

Then:

```bash
git add -- test/database_archive_coordinator_test.dart \
  test/database_archive_lifecycle_contract_test.dart \
  lib/official_capture/capture_session.dart \
  lib/official_capture/photo_archive_coordinator.dart \
  lib/official_capture/photo_archive_runtime.dart \
  lib/official_capture/sfm_resume.dart \
  lib/ui/me_page.dart
git commit -m "feat(archive): connect official database lifecycle"
```

## Task 5: Pinned portable ZPAQ native codec

**Files:**

- Create: `test/database_archive_ffi_contract_test.dart`
- Create: `lib/official_capture/database_archive_ffi_codec.dart`
- Create: `ios/Runner/pw_zpaq_bridge.h`
- Create: `ios/Runner/pw_zpaq_bridge.cpp`
- Create: `ios/RunnerTests/PWZpaqBridgeTests.mm`
- Create: `ios/Vendor/Zpaq/**`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Modify: `ios/Runner/Info.plist`
- Modify: `pubspec.yaml`
- Modify: `THIRD_PARTY_NOTICES`

- [ ] **Step 1: Write failing native/FFI contract tests**

The Dart test reads source/build files and requires:

```dart
for (final symbol in const <String>[
  'pw_zpaq_version',
  'pw_zpaq_revision',
  'pw_zpaq_error_message',
  'pw_zpaq_last_error',
  'pw_zpaq_compress_file',
  'pw_zpaq_decompress_file',
  'pw_zpaq_request_cancel',
]) {
  expect(header, contains(symbol));
  expect(bridge, contains(symbol));
  expect(dart, contains(symbol));
}
expect(bridge, contains('libzpaq::compress'));
expect(bridge, contains('\"5\"'));
expect(project, contains('libzpaq.cpp in Sources'));
expect(project, contains(r'$(PROJECT_DIR)/Vendor/Zpaq/include'));
expect(project, contains('-Wl,-u,_pw_zpaq_compress_file'));
expect(infoPlist, contains('future-official-zpaq-db-archive-v1'));
expect(notices, contains(DatabaseArchivePolicy.pinnedRevision));
expect(File('ios/Vendor/Zpaq/Zpaq-LICENSE.txt').lengthSync(), greaterThan(0));
```

- [ ] **Step 2: Run and verify RED**

```bash
flutter test test/database_archive_ffi_contract_test.dart
```

Expected: missing native files, Dart binding, project references, marker, and
notices fail the assertions.

- [ ] **Step 3: Vendor exact source and implement the portable bridge**

Copy only these already-audited benchmark files without downloading:

```text
/Users/kaidongwang/Developer/pocketworld-jxl-bench/.worktrees/implementation/ios/Vendor/Zpaq/include/libzpaq.h
/Users/kaidongwang/Developer/pocketworld-jxl-bench/.worktrees/implementation/ios/Vendor/Zpaq/src/libzpaq.cpp
/Users/kaidongwang/Developer/pocketworld-jxl-bench/.worktrees/implementation/ios/Vendor/Zpaq/Zpaq-LICENSE.txt
/Users/kaidongwang/Developer/pocketworld-jxl-bench/.worktrees/implementation/ios/Vendor/Zpaq/REVISION
/Users/kaidongwang/Developer/pocketworld-jxl-bench/.worktrees/implementation/ios/Vendor/Zpaq/SHA256SUMS
```

Verify the copied source hashes against `SHA256SUMS`. The bridge is pure C++17,
defines `libzpaq::error` as a caught exception, streams `FILE*` through
`libzpaq::Reader`/`Writer`, flushes and `fsync`s output, rejects every method
except 5, and checks a process-global atomic cancellation generation from both
reader and writer callbacks. Each Dart operation captures the current
generation; foreground activity increments it, so one operation cannot consume
or clear a newer cancellation request. Compile bridge and libzpaq with
`-DNOJIT -Dunix`.

- [ ] **Step 4: Implement Dart FFI and native round-trip test**

`ZpaqFfiDatabaseArchiveCodec`:

```dart
class ZpaqFfiDatabaseArchiveCodec implements DatabaseArchiveCodec {
  @override
  bool get isSupported =>
      Platform.isIOS && _NativeZpaqBindings.tryLoad() != null;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) => Isolate.run(() => _compressFile(
        sourceDatabase.path,
        destinationArchive.path,
      ));

  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) => Isolate.run(() => _decompressFile(
        sourceArchive.path,
        destinationDatabase.path,
      ));

  @override
  void requestCancellation() => _NativeZpaqBindings.tryLoad()?.requestCancel();
}
```

Bindings require native version `7.15` and the pinned revision. Native cancelled
status maps to `const DatabaseArchiveCancelled()`; all other nonzero statuses
include both `pw_zpaq_error_message` and `pw_zpaq_last_error`.

`PWZpaqBridgeTests.mm` writes a compressible deterministic fixture, calls
method 5, decompresses, and asserts `NSData` equality plus exact version and
revision. It removes all temporary files in `@finally`.

- [ ] **Step 5: Link, ship notices, run tests, and commit with native warning**

Add bridge/libzpaq to Runner Sources, the round-trip test to RunnerTests Sources,
the license to Resources, the ZPAQ include directory to all Runner build
configurations, and `-Wl,-u` flags for every exported runtime symbol. Append the
ZPAQ license directory to Flutter assets and exact provenance to
`THIRD_PARTY_NOTICES`. Append `+future-official-zpaq-db-archive-v1` to
`PWBuildExperimentMarker`.

Run:

```bash
flutter test test/database_archive_ffi_contract_test.dart
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:RunnerTests/PWZpaqBridgeTests test
```

Commit exact files only:

```bash
git add -- test/database_archive_ffi_contract_test.dart \
  lib/official_capture/database_archive_ffi_codec.dart \
  ios/Runner/pw_zpaq_bridge.h ios/Runner/pw_zpaq_bridge.cpp \
  ios/RunnerTests/PWZpaqBridgeTests.mm ios/Vendor/Zpaq \
  ios/Runner.xcodeproj/project.pbxproj ios/Runner/Info.plist \
  pubspec.yaml THIRD_PARTY_NOTICES
git commit -m "feat(archive): add ZPAQ 7.15 database codec（需重编 native）"
```

## Task 6: Verification, review, and production update

**Files:**

- Modify: only the OpenSpec task checklist after each gate passes.

- [ ] **Step 1: Format only touched Dart files**

```bash
dart format \
  lib/official_capture/database_archive_codec.dart \
  lib/official_capture/database_archive_ffi_codec.dart \
  lib/official_capture/database_archive_policy.dart \
  lib/official_capture/database_archive_manifest.dart \
  lib/official_capture/database_archive_transaction.dart \
  lib/official_capture/database_archive_resolver.dart \
  lib/official_capture/capture_session.dart \
  lib/official_capture/photo_archive_coordinator.dart \
  lib/official_capture/photo_archive_runtime.dart \
  lib/official_capture/sfm_resume.dart \
  lib/ui/me_page.dart \
  test/database_archive_policy_test.dart \
  test/database_archive_transaction_test.dart \
  test/database_archive_resolver_test.dart \
  test/database_archive_coordinator_test.dart \
  test/database_archive_lifecycle_contract_test.dart \
  test/database_archive_ffi_contract_test.dart
```

- [ ] **Step 2: Run deterministic repository gates**

```bash
flutter test --no-pub test/database_archive_policy_test.dart \
  test/database_archive_transaction_test.dart \
  test/database_archive_resolver_test.dart \
  test/database_archive_coordinator_test.dart \
  test/database_archive_lifecycle_contract_test.dart \
  test/database_archive_ffi_contract_test.dart \
  test/photo_archive_coordinator_test.dart \
  test/photo_archive_lifecycle_contract_test.dart
flutter test --no-pub
flutter analyze --no-pub
openspec validate add-future-official-zpaq-database-archive --strict
git diff --check
```

Expected: zero failing tests, zero analyzer errors, valid OpenSpec, and no
whitespace errors. Existing unrelated dirty files remain unstaged.

- [ ] **Step 3: Build and inspect without installing**

Use a task-specific Flutter config and `/private/tmp` output:

```bash
env XDG_CONFIG_HOME=/private/tmp/pw-zpaq-flutter-config \
  FLUTTER_BUILD_DIR=/private/tmp/pw-zpaq-build \
  flutter build ios --release --no-codesign --no-pub
```

Inspect:

```bash
plutil -p /private/tmp/pw-zpaq-build/ios/iphoneos/Runner.app/Info.plist
nm -gU /private/tmp/pw-zpaq-build/ios/iphoneos/Runner.app/Runner \
  | rg 'pw_zpaq_(version|revision|compress_file|decompress_file|request_cancel)'
codesign --verify --deep --strict \
  /private/tmp/pw-zpaq-build/ios/iphoneos/Runner.app
```

The unsigned build may make the final `codesign` gate explicitly unavailable;
the signed production build must pass it before installation.

- [ ] **Step 4: Re-read the integrated diff and commit only owned artifacts**

Verify:

```bash
git status --short
git diff --stat
git diff -- \
  lib/official_capture/database_archive_codec.dart \
  lib/official_capture/database_archive_ffi_codec.dart \
  lib/official_capture/database_archive_policy.dart \
  lib/official_capture/database_archive_manifest.dart \
  lib/official_capture/database_archive_transaction.dart \
  lib/official_capture/database_archive_resolver.dart \
  lib/official_capture/capture_session.dart \
  lib/official_capture/photo_archive_coordinator.dart \
  lib/official_capture/photo_archive_runtime.dart \
  lib/official_capture/sfm_resume.dart lib/ui/me_page.dart \
  ios/Runner/pw_zpaq_bridge.h ios/Runner/pw_zpaq_bridge.cpp \
  ios/RunnerTests/PWZpaqBridgeTests.mm \
  ios/Runner.xcodeproj/project.pbxproj ios/Runner/Info.plist \
  pubspec.yaml THIRD_PARTY_NOTICES
```

Do not use `git add -A`, `git add -u`, `commit -a`, stash, reset, checkout, or
global formatting.

- [ ] **Step 5: Apply the production iPhone update runbook**

Before installation:

```bash
git fetch origin
git log --oneline -5
git status --short
```

If `origin/main` is ahead, commit only this feature's owned files and integrate
without touching others' dirty work. Back up `Documents` and `Library`
separately through the app-data-container domain, hash every copied file, and
verify the backup. Build signed output under `/private/tmp` with `--no-pub`;
verify bundle ID `com.kyle.PocketWorld`, deep signature, ABI symbols, and the
ZPAQ `Info.plist` marker. Install only with:

```bash
xcrun devicectl device install app --device <connected-device-id> \
  /private/tmp/<verified-build>/Runner.app
```

There is no uninstall command. After update, recopy and hash `Documents` and
`Library`; require every pre-existing file to remain byte-identical except
`Library/SplashBoard/Snapshots/**`. Report `UPDATE_COMPLETE` and the installed
HEAD.

Create one isolated new official project and verify:

```text
new database marker exists
-> raw official_sfm_live.db reaches a cold closed state
-> method-5 archive and manifest commit
-> raw database is removed only after exact restore verification
-> explicit recovery recreates the original length and SHA-256
-> historical projects remain unmarked and unchanged
```
