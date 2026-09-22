# Tasks

- [x] Add failing pure-Dart tests for horizontal, vertical, radial, rotation,
  diagonal-overlap, and unavailable-health cases.
- [x] Implement projection, motion decomposition, overlap, and adaptive angle
  selection in the geometry layer.
- [x] Add role-aware governor decisions and motion-driven normal cadence.
- [x] Maintain separate capture and geometry baselines in the controller.
- [x] Extend telemetry without changing the existing shutter path.
- [ ] Make rotation coverage win a simultaneous rotation/radial eligibility
  collision while preserving overlap-safety and geometry precedence.
- [ ] Emit exactly four role keys in candidate/selected/blocked/fired maps, put
  no-candidate decisions in a separate scalar, and enforce all terminal
  conservation equations.
- [ ] Add collision and count-conservation regression tests.
- [ ] Capture a real startup anchor, keep it outside the four-role ledger, and
  retry rejected admission without creating a phantom baseline.
- [x] Run focused Flutter tests and static analysis.
- [x] Leave phone installation blocked until the production update runbook is
  separately authorized and completed.
