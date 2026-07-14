## 1. Baseline and Failure Tests

- [ ] 1.1 Freeze baseline `1626543` behavior and line-level failure inventory in a checked-in test note.
- [ ] 1.2 Add failing pure-Dart lifecycle tests for immutable IDs, monotonic/idempotent transitions, and exact set closure.
- [ ] 1.3 Add failing fault-injection tests for late listener startup, out-of-order completion, nil gray, queue write/read failure, non-OK native ack, finish during backlog, and dispose/restart.
- [ ] 1.4 Add failing tests proving coverage replacement and curation cannot remove a raw capture.
- [ ] 1.5 Add failing deletion tests for pending writers, already-ingested frames, and directory non-resurrection.

## 2. Append-Only Capture Ledger

- [ ] 2.1 Implement the immutable capture job, state transition reducer, and append-only local ledger.
- [ ] 2.2 Add a capture-owned observable raw-photo catalog independent of `DomeTargetPoints`.
- [ ] 2.3 Move album count/list and bundle-manifest ownership to the capture ledger.
- [ ] 2.4 Replace automatic raw prune with non-destructive curation metadata.
- [ ] 2.5 Persist user deletion tombstones and invalidate any derived reconstruction that consumed a deleted job.

## 3. Snapshot Ticket and Atomic Photo Commit

- [ ] 3.1 Add a platform `ManualCaptureTicket` protocol that separates snapshot reservation acknowledgement from completion.
- [ ] 3.2 Implement iOS per-job private staging, unique final publication, hashes, commit marker, and restart recovery.
- [ ] 3.3 Bound retained 4K snapshot memory with an observable spill-to-disk path and no accepted-job drop.
- [ ] 3.4 Add completion/error reporting that is race-safe when await/query starts before or after native completion.
- [ ] 3.5 Update the manual shutter UI to release busy state at reservation acknowledgement and add the AR card only after photo commit.

## 4. Durable SfM Queue and Registration Gate

- [ ] 4.1 Persist a frame-exact SfM input and queue record for every photo-committed active job before worker offer.
- [ ] 4.2 Replace the broadcast-only feed dependency with ordered queue discovery/replay.
- [ ] 4.3 Keep queue inputs through worker errors and delete or compact them only after proven registration or explicit user deletion.
- [ ] 4.4 Add tainted-database detection and clean replay from the immutable active queue after ambiguous native failure.
- [ ] 4.5 Gate finalize and user-visible completion on exact expected/committed/queued/ingested/registered ID equality.
- [ ] 4.6 Persist unregistered IDs and keep any sub-100% run blocked/retryable.

## 5. Thermal-Safe Background Scheduling

- [ ] 5.1 Add failing-first pure scheduler tests for nominal, fair, serious, critical, cooldown, and Metal-failure states.
- [ ] 5.2 Implement disk-backed pacing/pause that changes only background consumption and never the shutter denominator.
- [ ] 5.3 Record queue depth, RSS/footprint, thermal state, GPU return codes, pause/resume, and effective K without changing quality gates.
- [ ] 5.4 Verify existing K12→K6 behavior remains separately attributable and does not stand in for durable recovery.

## 6. Host Verification and Review

- [ ] 6.1 Run targeted Dart/Flutter tests for all state and fault cases without starting a phone or heavy model workload.
- [ ] 6.2 Run format, analyze, deterministic queue checks, and OpenSpec strict validation.
- [ ] 6.3 Review the exact diff against original dirty-worktree boundaries and confirm no cloud-removal WIP or backup libraries entered the branch.
- [ ] 6.4 Complete a fresh-context read-only code review and resolve every material finding.
- [ ] 6.5 Produce a host evidence bundle that labels all physical-device claims unverified.

## 7. Deferred iPhone 14 Pro Qualification

- [ ] 7.1 Record device/app/build/config hashes and run a cold 30-tap baseline.
- [ ] 7.2 Run a same-cell rapid 20-tap burst and prove no identity overwrite or unbounded footprint.
- [ ] 7.3 Run 10–15 minutes or at least 100 taps through nominal/fair/serious heat, including burst-then-Finish.
- [ ] 7.4 Exercise background/relaunch and controlled interruption at reservation, staged write, publication, queue, and ingestion boundaries.
- [ ] 7.5 Exercise pending and post-ingestion user deletion plus whole-capture discard without directory resurrection.
- [ ] 7.6 Verify exact ID-set equality and `registered / expected = 100%`; otherwise retain the bundle and report blocked with exact IDs.
- [ ] 7.7 Preserve telemetry, ledger, SHA-256 manifests, DB/WAL identity, final poses/PLY, and thermal/RSS timeline for review before merge.
