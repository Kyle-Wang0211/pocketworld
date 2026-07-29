# Future Official-Capture ZPAQ Database Archive Design

## Outcome

Only official captures created after this feature is installed are eligible for
database archiving. After official reconstruction has durably persisted its
final artifacts and released SQLite, the app may replace
`official_sfm_live.db` with a smaller ZPAQ 7.15 method-5 archive. The source
database is deleted only after a real decompression proves exact original-byte
identity.

The retired self-developed capture pipeline is out of scope. No marker, hook,
resolver, migration, or archive behavior is added under `captures/` or for
`sfm_live.db`.

## Product invariants

- Existing projects are never migrated or opportunistically marked.
- Eligibility requires a database-archive policy marker created with a new
  official capture.
- “Lossless” means the restored database has the same byte length and SHA-256
  as the source database.
- The source database remains authoritative until compression, decompression,
  verification, archive publication, and manifest commit all succeed.
- Archive work never runs while official capture, reconstruction, recovery, or
  another archive transaction owns the project.
- A database with `-wal` or `-shm` sidecars is not eligible. The coordinator
  waits for a later clean-close opportunity rather than guessing whether the
  SQLite state is complete.
- An archive that is not smaller than its source is discarded and the source
  database remains unchanged.
- Dart owns policy, scheduling, state, hashes, and transactions. The pinned,
  portable ZPAQ C++ implementation owns the codec primitive.
- Unsupported platforms fail closed and preserve the source database. The
  archive format and native core are not Apple-specific.

## Scope and lifecycle

```text
new official capture directory
  -> write official database archive policy marker
  -> capture and official SfM update official_sfm_live.db
  -> persist non-empty final PLY + sparse metadata
  -> close reconstruction worker and SQLite
  -> existing official cold-archive coordinator becomes idle
  -> run JPEG XL photo transaction
  -> run ZPAQ database transaction
  -> exact-database resolver for later recovery
```

Startup discovery scans only marker-bearing directories below
`captures_official/`. The durable artifact checks remain authoritative; lifecycle
notifications only wake the coordinator.

The ZPAQ transaction is added to the existing official cold-archive coordinator
after its JPEG XL work. This reuses the coordinator's serialization and active
reconstruction guards and avoids introducing a second owner for the official
pipeline.

## Stored files

Each eligible capture may contain:

- `official_database_archive_policy.json`: immutable eligibility gate with
  schema, source filename, codec, method, and pinned source revision;
- `official_sfm_live.db.zpaq`: committed archive;
- `official_database_archive.json`: atomic transaction manifest containing
  original and archive lengths and SHA-256 values, codec identity, method, and
  verification status.

Temporary output uses capture-local names:

- `official_sfm_live.db.zpaq.tmp`;
- `official_sfm_live.db.verify.tmp`;
- an atomic temporary manifest.

All recorded paths are fixed basenames. Manifests never authorize arbitrary or
parent-relative filesystem paths.

## Archive transaction

```text
official_sfm_live.db
  -> require compatible future-project policy marker
  -> require final PLY + metadata and no SQLite sidecars
  -> stream source length + SHA-256
  -> stream-compress to official_sfm_live.db.zpaq.tmp
  -> stream-decompress to official_sfm_live.db.verify.tmp
  -> require exact length, SHA-256, and byte equality
  -> reject if the archive is not smaller
  -> atomically replace official_sfm_live.db.zpaq
  -> atomically commit official_database_archive.json
  -> delete official_sfm_live.db last
```

The native bridge is path based and executes from a background Dart isolate.
Neither the database nor its restored contents are loaded wholesale into the
Dart heap.

If a prior archive exists because the database was restored for recovery, the
new verified archive atomically replaces it. The restored source remains until
the new manifest is committed, so a crash between archive replacement and
manifest replacement cannot lose the current database.

## Recovery and re-archiving

Recovery treats a raw `official_sfm_live.db` as authoritative. If the raw
database is absent, the resolver requires a compatible marker, manifest, archive
length/hash, and pinned codec before it restores.

Restoration writes a temporary database, verifies the manifest's original
length and SHA-256, then atomically publishes `official_sfm_live.db`. The archive
is retained as the last verified cold snapshot while reconstruction may mutate
the restored database.

After recovered reconstruction produces durable artifacts and releases SQLite,
the same coordinator archives the new database state and removes the raw
database again. A malformed, missing, incompatible, or corrupt archive is
reported as non-recoverable and is never handed to SQLite.

## Crash and failure behavior

- Compression, decompression, hash, size, or byte-comparison failure removes
  transaction temporaries and preserves the source database.
- Process termination before manifest commit leaves the source database.
- Process termination after manifest commit but before source deletion leaves
  both. Reconciliation revalidates the committed archive before removing the
  duplicate source.
- A stale manifest or mismatched archive never authorizes source deletion.
- Temporary-file cleanup is limited to fixed filenames inside a compatible,
  marker-bearing official capture.
- Native unavailability, version mismatch, or unsupported ABI postpones work
  without changing project data.

## Codec and licensing

Production vendors the exact ZPAQ 7.15 source revision already exercised by the
accepted benchmark. The product records its source archive SHA-256 and carries
the upstream license and notices. The FFI API exposes explicit version,
revision, compression, and decompression entry points; the app rejects a codec
whose reported identity differs from the policy.

The initial build compiles the portable core for iOS. Future platforms compile
the same core behind the same Dart contract rather than substituting a
platform-specific compression algorithm.

## Verification

Tests must cover:

- future-only marker creation and rejection of unmarked historical projects;
- successful archive, decompression, exact SHA-256, manifest commit, and
  source deletion;
- codec failure, corrupt output, SHA mismatch, unsafe metadata, sidecar
  presence, and non-smaller output preserving the source;
- reconciliation at every publish/delete crash boundary;
- raw-database preference, archive-only recovery, corrupt-archive rejection,
  and recovery followed by re-archive;
- coordinator serialization and pause behavior during official reconstruction;
- native version/revision checks and method-5 byte-exact round trips;
- Xcode source, linker, signing, license, and build-marker integration.

Production acceptance requires the relevant Dart tests, static analysis, native
tests, an iOS release build, and a physical-iPhone end-to-end verification using
an isolated new official project. Device installation remains an in-place
update with a verified `Documents` and `Library` backup; uninstall/reinstall is
never permitted.
