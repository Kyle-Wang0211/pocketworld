# Project Research and Engineering Policy

## Delegated Execution Fast Path

When a task arrives inside `<codex_delegation>` from another Codex task and its
prompt requests direct implementation, testing, or experiment execution:

- Treat it as an already-dispatched bounded subtask. Do not reload
  `using-superpowers` or any other `SKILL.md`, and do not repeat planning,
  contracts, audits, or repository orientation unless the delegated prompt
  explicitly requests them.
- Emit the exact first command and execute it within 30 seconds. A skill-read,
  plan, or status-only message does not count as progress.
- After every tool result, immediately continue to the next command or edit.
  If no reasoning, tool, or file-change event can run for 30 seconds, report
  `SCHEDULER_STARVED` instead of remaining indefinitely in a generic `Working`
  state.
- Respect the delegated exclusive write domain and preserve all existing dirty
  work. Never reset, revert, clean, stage-all, or commit unless explicitly
  requested.
- A delegation marked `leaf_worker` is already the terminal worker. It must not
  spawn, wait for, or message another agent/thread. The launcher disables
  `features.multi_agent_v2` for these processes so a worker cannot recursively
  create a second scheduler tree.

DA3 is no longer the active algorithm direction. Do not automatically load or
apply `docs/da3_image_only_long_term_memory_2026-06-06.md`; it is retained only
as historical evidence. Use it only when the user explicitly asks about that
retired DA3 work.

Before changing or evaluating an algorithm in this workspace:

1. Identify the active algorithm repository, upstream revision, baseline,
   supported platforms, and product constraints.
2. Record intended behavior and non-trivial changes in OpenSpec. Do not maintain
   a parallel Spec Kit workflow.
3. Define metrics, thresholds, exclusions, seeds, input/model/config hashes,
   hardware/backend, stopping rules, and required artifacts before the run.
4. Use a repository-local `uv.lock` for Python reproducibility, DVC for data and
   large artifact identity, and MLflow for run metadata and metrics.
5. Preserve failed runs and label baselines, deviations, ablations, diagnostics,
   and product routes explicitly. Do not present a stronger alternative as a
   faithful reproduction of a selected upstream algorithm.
6. For substantial work, apply the global multi-agent workflow: disjoint
   implementation ownership, an experiment/reproduction path, independent
   read-only review, deterministic verification, and main-agent adjudication.

Project code, tests, effective configurations, hashes, and artifacts outrank
chat summaries or agent memory when claims conflict.

## PocketWorld Production Device Data Invariant

- Treat the user's daily-use iPhone app bundle `com.kyle.PocketWorld` and its
  App Data Container as irreplaceable user data.
- Never uninstall, reinstall, delete, or replace that production bundle as a
  testing or deployment shortcut. Never run `flutter drive` against that bundle;
  its cleanup can uninstall the app and erase Documents, authentication state,
  and locally captured projects.
- Device deployment is allowed only through an incremental update path that is
  known to preserve the existing App Data Container. If preservation cannot be
  proven before the command, stop and ask the user instead of deploying.
- Put automated integration tests on a separate test bundle identifier and
  separate container. A successful build does not authorize installation on the
  production device.
- Before any permitted update, take and verify a recoverable container backup.
  Updating code must never require the user to log in again or lose local data.

## PocketWorld Production iPhone Update Runbook

This runbook is durable project policy. Do not improvise a new installation
path or download/upgrade a different Flutter/Xcode dependency during a device
update.

### Local Product Baseline Preservation Invariant

- The current complete local PocketWorld product tree is the only permitted
  source baseline for subsequent product work. This includes tracked,
  uncommitted, staged, and intentionally untracked product source. Never use an
  older commit, detached worktree, historical `Runner.app`, historical Dart
  AOT, or reconstructed source snapshot as the carrier for a newer native or
  algorithm change.
- A request to change one native algorithm or framework does not authorize
  rebuilding or replacing the product from an older source identity. Apply the
  authorized delta on top of an immutable snapshot of the current local product
  tree, and preserve every unrelated local behavior and file.
- Before any candidate build, record the current local product HEAD plus a
  content manifest covering tracked, staged, uncommitted, and relevant
  untracked source. The candidate must be traceable to that exact manifest.
  Git commit identity alone is insufficient for a dirty working tree.
- For a native-only change, build an unchanged control and the candidate from
  the same frozen local product snapshot. The Flutter/Dart inputs must have the
  same manifest, and the resulting `App.framework` Dart AOT must be
  byte-identical between control and candidate. Only the explicitly authorized
  native artifact may differ. If this cannot be proven, stop; do not sign,
  install, or request device authorization.
- Never reset, clean, checkout over, or otherwise discard local product changes
  to make a build reproducible. Create an isolated copy that preserves the full
  local file state instead. Never treat preservation of the iOS App Data
  Container as proof that the installed application code was preserved: an
  in-place install replaces the signed app bundle even when user data survives.
- Device authorization is never inferred from local implementation work. If the
  user declines device authorization, all signing, installation, launch, and
  device mutation stop; continue only with local diagnosis and verification.

- Reuse the repository's already pinned and previously verified Flutter SDK,
  package cache, signing team, bundle identifier, and native artifacts. A
  deployment task is not authorization to fetch a newer SDK, resolve against a
  different toolchain, or rebuild native dependencies from another revision.
- Device-update builds must pass `--no-pub`. For isolated PocketWorld checkouts,
  map the expected sibling `dist` and `Aether3D-cross` paths to the existing
  product-local artifacts only after verifying their pinned hashes; never fetch
  or substitute a missing archive during an update.
- Run CoreDevice, code-signing, and device-install commands in the user's normal
  macOS Terminal session. Codex's sandbox can intermittently list the phone but
  cannot reliably initialize or restart `CoreDeviceService` and cannot access
  the user's signing identity. A sandbox timeout must never trigger a different
  bundle, fresh install, or unverified packaging shortcut.
- Use one dedicated Terminal window for the update. Reuse it for diagnostics,
  close finished Codex-owned windows immediately, and never leave a stack of
  completed Terminal windows on the user's desktop.
- Back up `Documents` and `Library` separately through the app-data-container
  domain, hash every copied file, and verify the hashes before building or
  installing. Do not copy the container root (`--source .`): iOS protects
  `.com.apple.mobile_container_manager.metadata.plist`, and requesting it makes
  an otherwise valid backup fail after most user data has already transferred.
- Keep Flutter configuration isolated with a task-specific
  `XDG_CONFIG_HOME`. Put signed Flutter/Xcode build output under
  `/private/tmp`, not anywhere under Documents/File Provider. File Provider can
  attach `com.apple.FinderInfo` or resource-fork metadata to
  `Flutter.framework`, which makes `codesign` fail with “resource fork, Finder
  information, or similar detritus not allowed.”
- Before the in-place update, verify the produced app has bundle ID
  `com.kyle.PocketWorld`, a valid deep signature, the required native ABI
  symbols, and an explicit signed `Info.plist` experiment marker. Dart AOT
  strings are not a stable build-identity check. Install only with
  `devicectl device install app`; there must be no uninstall command anywhere
  in the flow.
- After the update, copy `Documents` and `Library` back from the phone and
  verify that every pre-existing file is still present and byte-identical.
  Exclude only `Library/SplashBoard/Snapshots/**` from identity comparison:
  iOS rotates those launch-screen textures during a normal in-place update.
  Record the excluded paths, but do not classify them as user-data loss.
  Report completion only after both this check and the explicit
  `UPDATE_COMPLETE` terminal marker succeed.
- Any failure before `UPDATE_COMPLETE` is a stopped update, not permission to
  try a different package. Preserve the verified backup and diagnose the exact
  failed stage before retrying.

## PocketWorld Phone-Only Production Validation Invariant

- Any PocketWorld production A/B test, benchmark, quality comparison, speed
  comparison, or parameter-acceptance experiment must run end-to-end on the
  user's physical iPhone through the actual mobile production pipeline. This
  includes the real Metal matcher, iOS scheduling and thermal behavior, ARKit
  inputs, mobile BA/filtering path, and final PLY generation.
- Host, desktop, simulator, or standalone COLMAP replays may be used only for
  diagnostics, harness development, and hypothesis generation. Their results
  must never select a production winner, approve a production parameter, or be
  reported as proof of product speed, quality, or parity.
- If the physical-phone production pipeline cannot execute the requested test,
  report the experiment as blocked. Never silently substitute host evidence.
- Preserve the immutable source capture and run phone experiments on isolated
  copies so every compared arm uses the same cached inputs and differs only in
  the explicitly declared variable.
