## 1. Contract and TDD

- [ ] 1.1 Add RED tests for candidate selection, per-candidate exactness,
      tie-breaking, fallback, manifest v1/v2 compatibility, and track restore.
- [ ] 1.2 Add RED coordinator tests for preprocessing cancellation.

## 2. Production implementation

- [ ] 2.1 Add the Dart database preprocessor interface and iOS FFI adapter.
- [ ] 2.2 Compile the versioned native track transform into the app and expose
      cooperative cancellation.
- [ ] 2.3 Implement dual candidates, independent verification, minimum-size
      selection, v2 manifest publication, and complete temporary cleanup.
- [ ] 2.4 Implement resolver inverse restoration and runtime wiring while
      preserving v1 raw archive compatibility.

## 3. Independent iPhone bundle

- [ ] 3.1 Add a dedicated Dart benchmark entrypoint and result artifact.
- [ ] 3.2 Build with bundle ID `com.kyle.PocketWorld.ArchiveBench`, copy an
      immutable fixture only into that app container, and run three repeats.
- [ ] 3.3 Copy results back and verify source/restored SHA-256, bytes, SQLite
      integrity, deterministic selection, and temporary cleanup.

## 4. Verification

- [ ] 4.1 Run focused native/Dart tests, strict OpenSpec validation, scoped
      formatting, Flutter analysis, and the full Flutter test suite.
- [ ] 4.2 Inspect only owned diffs and report HEAD plus the independent bundle
      identifier; do not install the production bundle.
