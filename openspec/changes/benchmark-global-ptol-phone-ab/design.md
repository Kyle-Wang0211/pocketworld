# Design

Use the already-installed build 32 and its startup `official_env.json` bridge.
For each arm, read the phone's shared environment file, change only
`OFFICIAL_AETHER_GLOBAL_PTOL`, push the merged file, restart the app, and submit
an existing `pw_b1_gate_request.json` for `cap_1787545807521946`.

Only `rebuild_full` is compared. `rebuild_pruned` is produced by the reused gate
but is neither the same input nor a replicate and is excluded from the PTOL
metric. Raw gate output, `official_finalize_segments.json`, native telemetry,
and the environment receipt are pulled immediately after every arm.

The environment file is only the requested-input receipt. After constructing
the native solver options and before the first solve in an arm, the native
boundary emits an effective-options receipt containing the run and arm IDs,
stamped application/source/Dart/native identities, and the effective global
and local `parameter_tolerance` values. The control receipt must read
`global=0, local=0`; the candidate receipt must read
`global=1e-8, local=0`. No local tolerance environment key or code path is an
experimental variable. A missing identity, `UNSTAMPED` sentinel, value
mismatch, late receipt, or receipt/telemetry disagreement invalidates the arm.

The direction-screen order is ABAB. A follow-up BA pair is permitted only when
the first four runs are inconclusive. All records are persisted before the next
arm begins. The screen writes only isolated gate files and the shared
environment key; the source capture remains read-only. Fresh verified Documents
and Library backups precede the first write, and the environment key is restored
afterward.

A promising screen unlocks a separate signed benchmark bundle,
`com.kyle.PocketWorld.PtolBench`. It links the exact registered production
framework, imports the same production resume/finalize code, and uses a separate
container populated with hash-verified copies of the frozen archive. Both arms
run in the same benchmark build and persist refined PLY, complete summaries,
BA-round telemetry, and raw hashes. The benchmark bundle never targets or
mutates the production bundle or its container.
