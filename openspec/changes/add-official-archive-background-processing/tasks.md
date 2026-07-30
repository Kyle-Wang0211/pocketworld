## 1. Specification and audit state

- [x] 1.1 Record approved background, full-photo-retention, retry, and audit behavior
- [x] 1.2 Add failing tests for append-only audit history and atomic latest status
- [x] 1.3 Implement the filesystem-backed audit store

## 2. Coordinator scheduling and interruption

- [x] 2.1 Add failing tests for immediate scheduling, queue drain cancellation, expiration pause, and later retry
- [x] 2.2 Add scheduler/audit ports and generation-based interruption to the official coordinator
- [x] 2.3 Add failing tests that failed transactions stop the pump and remain discoverable
- [x] 2.4 Implement later-opportunity retry without tight in-process looping

## 3. Dart background entry

- [x] 3.1 Add failing MethodChannel tests for ready, run, cancel, and work-remaining results
- [x] 3.2 Implement the platform-neutral Dart background controller and iOS scheduler adapter
- [x] 3.3 Initialize the controller before normal startup discovery

## 4. Native iOS task

- [x] 4.1 Add failing source/Xcode contract tests for identifier, registration, expiration, task completion, and no-power/no-network requirements
- [x] 4.2 Implement and register the dedicated Swift `BGProcessingTask` bridge
- [x] 4.3 Add the permitted identifier and Xcode source membership

## 5. Verification and device update

- [x] 5.1 Format only owned Dart files and run focused background/archive tests
- [x] 5.2 Run full analysis/tests and strict OpenSpec validation
- [ ] 5.3 Build signed iOS Release with pinned dependencies and verify bundle/task identifiers
- [ ] 5.4 Back up and hash Documents/Library, install only in place, verify post-install identity, and report HEAD
- [ ] 5.5 On the next newly completed official project, verify audit events, background continuation, exact archive manifests, and absence of deleted unverified sources
