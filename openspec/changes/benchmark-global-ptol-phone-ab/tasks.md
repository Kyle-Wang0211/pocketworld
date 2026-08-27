# Tasks

- [ ] Freeze and verify the current phone, build, framework, and capture hashes.
- [ ] Back up and hash-verify Documents and Library separately.
- [ ] Record the pre-run shared environment file and reconstruction activity.
- [ ] Run the zero-rebuild A, B, A, B direction screen serially on the frozen
  capture.
- [ ] Persist and verify each raw report before starting the next arm.
- [ ] Persist and verify the native effective-options receipt before accepting
  any arm result.
- [ ] Reject any arm whose required identity is absent or `UNSTAMPED`, whose
  effective values differ from control `global=0, local=0` or candidate
  `global=1e-8, local=0`, or whose receipt arrives after native work begins.
- [ ] Parse BA rounds, finalize segments, speed, quality, and thermal evidence.
- [ ] Compute the A/A noise floor and paired A/B effect.
- [ ] Restore the original environment key and verify production data identity.
- [ ] Record a promising, negative, invalid, or blocked screen verdict without
  changing the shipping default.
- [ ] If promising, build and verify the separate PTOL benchmark bundle.
- [ ] Copy the frozen input into the benchmark container and run full ABAB.
- [ ] Persist per-arm PLY and complete quality evidence for visual review.
- [ ] Record a candidate or negative full-phone verdict without changing the
  shipping default.
