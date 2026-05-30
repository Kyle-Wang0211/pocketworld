# Algorithm Executor Boundary

This project treats Flutter/Dart as the algorithm contract center.

Hard rule:

```text
Dart sealed spec -> thin executor -> Dart report/audit -> next stage
```

No new heavy algorithm stage should add Swift, CUDA, C++, Metal, or FFI strategy before the Dart side owns a sealed spec, report schema, artifact contract, and quality/audit gate.

## Ownership

| Area | Dart owns | Native/FFI executor owns |
| --- | --- | --- |
| Capture / ARKit | save policy, cell/slot naming, metadata schema, quality gates, coverage logic | ARSession, camera pixel buffers, JPEG encoding, intrinsics/extrinsics reads |
| DA3 depth | model allowlist, K/window graph, input size, bridge frames, visual retrieval abstraction, dense Sim3 policy, streaming alignment, downstream handoff | CoreML load/forward, fixed tensor preparation, tensor writes, RSS/CPU/thermal/jetsam probes |
| Pointcloud | voxel size, frame skip, Sim3 application, confidence filter, normal policy, quality gates | point projection kernels, dedup kernels, PLY/temporary binary writes |
| Mesh | Poisson/BPA policy, simplification limits, hole/failure policy, report schema | reconstruction kernels and mesh file writes |
| Texture | photo selection, UV/bake policy, highlight/material handoff, atlas quality gates | xatlas/bake kernels and image writes |
| Compress | target format, LOD policy, meshoptimizer/KTX2 parameters, fallback rules | encoder invocations and byte output |
| Material | prompt/descriptor version, thresholds, cache policy, when material affects highlight strategy | model forward and descriptor extraction |
| MoGe / pre-SAP uncertainty | DA3-only vs DA3+MoGe routes, patch policy, MoGe auxiliary role, uncertainty metrics, SAP quality gate | MoGe forward pass, raw depth/normal/mask writes, patch feature extraction, benchmark head fitting |
| Device health | pause/resume/abort policy, risk labels, retry policy | raw thermal/RSS/jetsam/CPU probes |
| Social/viewer | feed ranking, cache policy, optimistic like state, fallback decisions | renderer draw calls and GPU resource creation |

## Required Dart Artifacts

Every algorithm stage must have:

- A sealed Dart spec describing exactly what the executor is allowed to run.
- A Dart report schema with structured success, failure, telemetry, and artifact paths.
- A Dart audit/quality gate that decides whether downstream stages may consume the result.
- A stable artifact naming contract.
- A clear executor boundary in the report, so real-device captures prove policy stayed in Dart.

## Executor Restrictions

Executors may return raw results, artifact paths, telemetry, and structured errors.

Executors must not decide product policy, thresholds, cache naming, window/frame selection, user-visible state, loop acceptance, geometry acceptance, or downstream consumption rules.

For Stage 1 DA3, this boundary is emitted into:

- `stages/depth/depth_index.json` as `algorithm_executor_boundary`
- `stages/depth/depth_runner_report.json` as `algorithm_executor_boundary`
- `stages/depth/da3_real_device_audit.json` as `algorithmExecutorBoundary`

For MoGe pre-SAP testing, the boundary starts in:

- `lib/pipeline/pre_sap_uncertainty_benchmark.dart`
- `pre_sap_uncertainty_spec.json`
- `pre_sap_uncertainty_report.json`

MoGe is treated as a shadow uncertainty signal, not a DA3 replacement. The
first gate is whether `DA3 + MoGe` improves bad-patch ranking, calibration, and
cross-view proxy consistency over `DA3 only`.

## Device Health Contract

The local runner now follows the same rule for device health:

- iOS `DeviceHealthPlugin` returns only raw samples: thermal state, RSS, jetsam/available memory, CPU, low-power state, processor counts, and app state.
- Dart `DeviceHealthPolicy` decides whether to proceed, mark high risk, pause once, or abort retryably.
- `serious` thermal is recorded as high risk and continues by default, because real DA3 captures are expected to be hot and the production requirement is to finish if memory is safe.
- `critical` thermal or memory below policy thresholds aborts before the next stage.
- Every pre-stage decision is written to `pipeline_trace.jsonl` as `device_health_policy`.
