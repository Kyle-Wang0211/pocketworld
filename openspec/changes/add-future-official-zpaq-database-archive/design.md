## Context

The production official route stores its resumable SQLite state at
`captures_official/<captureId>/official_sfm_live.db`. The existing JPEG XL
feature already supplies a creation-time policy, final-artifact notification,
reconstruction/capture activity leases, startup discovery, and one sequential
cold-work queue. Database archiving can reuse these lifecycle facts, but it
needs an independent marker so existing captures that already carry the photo
marker do not become database-migration candidates.

The accepted 100 MiB physical-iPhone benchmark restored every candidate to the
same SHA-256. ZPAQ 7.15 method 5 produced 62,850,614 bytes versus 68,045,272
bytes for LZMA2 preset 9, so ZPAQ method 5 replaces the LZMA2 baseline for this
cold database route.

## Goals / Non-Goals

**Goals:**

- Archive only official captures whose database policy was created by this
  feature.
- Preserve the exact original SQLite file bytes and fail closed at every
  transaction boundary.
- Start only after final PLY/meta persistence and SQLite/reconstruction
  release.
- Keep explicit recovery working when only the verified archive remains.
- Re-archive a database after recovery mutates it.
- Keep policy and safety logic in Dart while compiling the same portable ZPAQ
  core for every supported platform.

**Non-Goals:**

- Adding any marker, resolver, hook, migration, or archive behavior to the
  retired self-developed `captures/` route.
- Recompressing historical official projects.
- Archiving a live SQLite database, WAL/SHM/journal sidecars, JPEGs, PLY files,
  thumbnails, or an entire project directory in one container.
- Replacing the accepted method-5 algorithm or selecting parameters from host
  evidence.
- Installing on the production iPhone before the repository's verified backup
  and in-place update gates pass.

## Decisions

### Eligibility uses a second creation-time marker

`CaptureSession` writes `official_database_archive_policy.json` before exposing
a new official capture directory. The marker fixes schema, source basename,
codec, version, revision, and method. Existing photo markers do not imply
database eligibility.

Startup discovery may enqueue a directory when either official archive marker
is compatible, but each transaction independently checks its own marker.
Malformed, missing, or unknown database policy leaves the database untouched.

### The existing official coordinator remains the single owner

After preview cleanup and JPEG XL work, `PhotoArchiveCoordinator` invokes one
database transaction if no capture/reconstruction activity is active. It
requests cooperative native cancellation whenever foreground activity begins
and never publishes or deletes the database after the continuation gate closes.

Recovery acquires an outer reconstruction lease, waits for any cancelling cold
transaction to stop, materializes the database, then starts official SfM. This
avoids a resolver/archive race without changing the currently shared
`official_capture/sfm_live_recon.dart`.

### The database transaction is conservative and atomic

For `official_sfm_live.db`, the transaction:

1. requires a compatible database marker, non-empty final PLY/meta, codec
   support, and no `-wal`, `-shm`, or `-journal` sidecar;
2. streams source length and SHA-256;
3. compresses to `official_sfm_live.db.zpaq.tmp`;
4. decompresses to `official_sfm_live.db.verify.tmp`;
5. requires exact length, SHA-256, and byte equality;
6. discards an equal-or-larger result;
7. atomically publishes `official_sfm_live.db.zpaq`;
8. atomically publishes `official_database_archive.json`;
9. deletes the source database last.

Any exception removes transaction temporaries and retains the source. A test
hook models process termination after manifest commit. Restart revalidates the
archive and the duplicate source before completing deletion.

### Restored raw data is authoritative

The resolver returns an existing raw database first, including historical raw
databases. Archive-only recovery additionally requires a compatible policy,
manifest, compressed-file length/SHA-256, codec identity, and restored-file
length/SHA-256. It writes and validates a temporary database before atomic
publication.

The archive remains as the last verified snapshot while recovery may mutate the
raw database. A later cold transaction distinguishes an unchanged duplicate
from a changed database by source SHA-256: unchanged data is reconciled;
changed data creates a new verified archive and manifest.

### Dart owns orchestration; portable C++ owns ZPAQ

The Dart codec runs file-oriented FFI calls in a background isolate and rejects
unexpected native version/revision values. The C bridge contains no Swift or
Apple compression API. It wraps the exact official libzpaq 7.15 source archive
whose SHA-256 is
`e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`.

The bridge exports version, revision, error, compress, decompress, and
cooperative-cancel functions. Cancellation uses an atomic generation counter:
each operation captures the current generation, and foreground activity
increments it. This prevents an older operation from clearing or consuming a
newer cancellation request. iOS compiles the source with `NOJIT`; future
platforms compile the same source behind the same Dart contract.

## Risks / Trade-offs

- **Method-5 latency and memory** → Run one database at a time, only after the
  official cold boundary, off the Dart UI isolate, and request cooperative
  cancellation when foreground work starts.
- **Cancellation can occur only at libzpaq I/O callbacks** → Capture/recovery
  waits for the active transaction to stop before consuming the same project;
  no source deletion occurs after the Dart continuation gate closes.
- **Crash after replacing an older archive but before manifest replacement** →
  the current raw database remains, so restart can safely recompress it.
- **Archive corruption with no raw database** → recovery fails closed and never
  hands unverified bytes to SQLite.
- **Native source increases build size** → compile only the required portable
  source with dead stripping and measure the signed/unsigned product delta.
- **Commercial distribution obligations** → preserve exact source identity,
  bundle upstream license text, and record the dependency in
  `THIRD_PARTY_NOTICES`; this is engineering evidence, not legal advice.

## Migration Plan

1. Land OpenSpec and Dart safety contracts.
2. Implement the marker, manifest, transaction, and resolver test-first.
3. Connect only the official creation, cold-work, and recovery paths.
4. Vendor and link the already-benchmarked ZPAQ source and pass native fixture
   round trips.
5. Run focused/full Flutter tests, analysis, OpenSpec validation, and the pinned
   unsigned iOS release build.
6. Before production installation, back up and hash `Documents` and `Library`,
   build with `--no-pub`, verify bundle identity/signature/native symbols/build
   marker, and use only an in-place `devicectl device install app` update.
7. Validate a newly created official project on the physical iPhone. Historical
   projects remain unmarked and unchanged.

Rollback disables new database-marker creation and scheduling. Existing verified
archives remain readable through the resolver.
