# PLR-Derived Brunsli Two-Photo Exact-JPEG Design

## Status

Approved for Mac-only research execution on 2026-08-03. This approval does not
assert that learned JPEG recompression will win. It approves a bounded
experiment that can produce a valid winner, loser, invalid, or blocked verdict.

Revision 1 removes the proposed 15–20 MB hard model-size ceiling. Model size is
now governed by complete byte accounting and an explicit break-even project
scale. This kept the then-registered formal gate unchanged while avoiding the false
conclusion that a fixed model which loses on a small project must also lose on a
large project.

Revision 2 closes four accounting and interpretation gaps. `M` is now the
smallest preregistered, byte-exact deployment storage form rather than a raw
training file; project-scope reachability is frozen at 300 photos; the formal
scope is permanently the self-contained per-project archive; and same-input
JXL sizes are explicitly unknown until their one allowed Phase 4 measurement.

Revision 3 separates provisional and final model accounting. Phase 0 records a
provable raw-artifact upper bound from the frozen architecture and exercises
the storage and CDF-parity harnesses; Phase 4 reruns the same frozen candidates
on the final trained artifact and uses only `final_M` for the terminal verdict.

Revision 4 corrects the formal denominator before training. The frozen pair is
bound to a verified 96-photo capture, not the previously unbound 141 count. It
also excludes the complete capture and its byte-identical `_v2` duplicate,
places the pair under experiment-local DVC identity, and freezes a 22-stage
grouped decoder plus cross-process CPU integer-CDF parity gate.

## Objective

Build one complete, independently decodable two-photo archive that uses a
pinned Brunsli exact-JPEG parser/reconstructor and a completed PLR-derived
target-aware entropy path for all Y, Cb, and Cr coefficients. Admit expansion
only when the complete effective candidate is strictly smaller than the sum of
the two same-input JPEG XL exact-JPEG archives and both original JPEG files are
restored byte for byte.

The implementation is an independent `PLR-derived completion`. It is not the
official PLR, PLLR, Microsoft 2016 collection codec, or a faithful reproduction
of an unavailable upstream bitstream.

## Scope

- Host: macOS Apple Silicon only for this experiment.
- Production code and the physical iPhone are out of scope.
- No 100 MB, eight-photo, or complete-project run is permitted before the
  two-photo gate passes.
- The codec design must retain a plausible iPhone ARM64 path and must not
  require CUDA-only decoding operations.
- No subagents are used for this task.

## Frozen inputs

The test pair is selected before encoding and cannot be replaced after results
are observed.

| Role | File | Bytes | SHA-256 | Trigger timestamp |
|---|---|---:|---|---:|
| A / root | `cell_85_slot_4.jpg` | 2,995,750 | `ac91faba107c41f891dbce7128f0ecc8e66cb451892e231479d8bf8b738e4be6` | 2.265686 |
| B / conditional target | `cell_85_slot_5.jpg` | 3,112,949 | `73ec448d66a2242f5d8a07d3531d9018f604d3a67b219a5689901734fce83e4e` | 2.584402 |

Both are 4224x2376 and are separated by 0.319 seconds. Their registered capture
order, ARKit/SfM state, shared tracks, matches, and visible sparse points are
part of the immutable input manifest when used by the conditional arm.

All 96 files from `analysis_cap_1779777762841797` and its byte-identical
`analysis_cap_1779777762841797_v2` duplicate are excluded from model training,
model selection, validation selection, and parameter tuning. Their ordered
content-manifest SHA-256 values are frozen before training. Byte-identical
copies of A and B are stored under the experiment's DVC data identity.

## Frozen baselines

### Formal acceptance baseline

The formal baseline is the sum of the two same-input libjxl 0.12.0
exact-JPEG, effort-10 archive sizes.

- The evidence audit found no saved JXL result for these exact two SHA-256
  inputs. The pre-execution baseline state is therefore `not_yet_measured`.
- Reuse saved, hash-matching results when present.
- If a same-input result does not exist, run each JXL encode/decode exactly once
  in Phase 4 and persist the result identity permanently.
- Never rerun the baseline for stability. Encoded byte size is deterministic
  evidence, not a noisy timing metric.
- Until those two runs finish, `J`, `H`, and `N_break_even` are unknown. Size
  estimates and reviewer hypotheticals must not enter the experiment result,
  stopping rules, or acceptance decision.

### Diagnostic production-relevance baseline

Record the sum of the two same-input Microsoft Rust Lepton 0.5.8 archives as a
diagnostic secondary baseline. This does not alter the formal JXL acceptance
line.

- Reuse saved same-input results, otherwise run each Lepton encode/decode once.
- If the candidate beats JXL but not Lepton, report
  `passes_frozen_jxl_gate_but_loses_existing_lepton_alternative`.
- Such a result is a valid research win against the frozen gate but is not a
  production promotion recommendation.

## Model storage accounting without an arbitrary ceiling

Model accounting applies to the canonical stored decoder dependency, not to a
training-only optimizer checkpoint. It includes weights, quantization or scale
tables, entropy buffers, architecture/version metadata, and any bytes required
to reproduce the decoder's integer CDF decisions.

`model_stored_bytes` is not the size of a naked `.pt` file. It is the minimum
complete persisted size among a fixed Phase 0 candidate set that can restore
the selected canonical deployment artifact byte for byte on a clean machine.
The registered storage candidates are:

1. uncompressed canonical deployment artifact;
2. Zstandard 1.5.7 level 22;
3. ZPAQ 7.15 method 5, source SHA-256
   `e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`.

Each candidate includes its envelope, manifest, codec identity, and all bytes
needed for clean-machine restoration. Each compressed arm must restore the
canonical deployment artifact length, bytes, and SHA-256 exactly. The minimum
of these three complete results defines `M`. No codec, level, dictionary, or
serialization may be added after terminal sizes are visible.

Phase 0 runs before final training. It must therefore record:

```text
provisional_model_raw_upper_bound_bytes =
    complete uncompressed bytes of the frozen untrained deployment artifact
```

This raw value is a provable upper bound only when the frozen architecture,
deployment precision, tensor shapes, metadata schema, and envelope make the
final raw artifact the same complete length. Zstd and ZPAQ results on untrained
weights are diagnostics; they must not be called mathematical upper bounds.
Immediately before Phase 4, rerun the unchanged raw/Zstd/ZPAQ candidate set on
the final trained deployment artifact, register both provisional and final
tables, and define `final_M` as the minimum final complete persisted size. Only
`final_M` enters `candidate_effective_bytes`, `H`, `N_break_even`, and the
terminal verdict.

The report must separately record:

- reference fp32 artifact size and SHA-256, when one exists;
- selected deployment precision and canonical uncompressed deployment bytes;
- canonical deployment artifact SHA-256;
- every registered storage candidate's codec revision, parameters, persisted
  bytes, persisted SHA-256, restored SHA-256, and byte-equality result;
- the winning storage candidate and final charged `M`.

A precision conversion is not automatically lossless model storage. If fp16,
int8, or another representation preserves every registered integer-CDF symbol
decision, it may be registered in Phase 0 as a decoder-equivalent deployment
serialization, with decision-parity evidence. If any CDF decision changes, it
is a distinct model arm, must be frozen before the terminal comparison, and
cannot be described as byte-exact compression of the fp32 model. Either model
arm remains subject to exact restoration of both original JPEG files.

Phase 0 effort prioritizes the deterministic CDF-decision trace and parity
evidence for registered deployment precisions. The three storage codecs remain
a fixed, bounded accounting step; they are not a parameter-search campaign.

There is no fixed 15 MB, 20 MB, or other absolute rejection threshold. A fixed
model is constant overhead while project data grows. An absolute ceiling would
incorrectly reject a larger model that may create more than enough stream
savings on a large project.

The formal experiment uses `96` photos because that is the verified number of
high-resolution JPEG files in the capture containing A and B. The two-photo
model charge is:

```text
formal_pair_model_charge = ceil(model_stored_bytes * 2 / 96)
```

At complete 96-photo project scale, the same accounting adds the model exactly
once. The pair formula is an allocation of that one shared model, not a claim
that the archive stores 2/96 of a physical file.

The result must also report model-overhead sensitivity for photo counts
`2`, `44`, `96`, `300`, `1,000`, and `10,000`. Only `96` determines this
experiment's formal verdict. `300` is the approved self-contained scope's
reachability boundary. `2`, `44`, `1,000`, and `10,000` are informational rows;
in particular, `1,000` and `10,000` have no decision authority under the
per-project scope and cannot rescue a losing candidate.

### Deployment scopes

The report must distinguish three storage scopes:

1. **One global model shared across projects.** Store one immutable model in the
   app/cloud decoder repository and reference it by hash. Its storage cost is
   divided across every photo that can legally and durably use that model.
2. **One model per project.** Store the model once in a self-contained project
   archive. For a project with `P` photos, a two-photo slice is charged
   `ceil(model_stored_bytes * 2 / P)` and the full project is charged the model
   once.
3. **One model per photo.** Charge the entire model to every photo. This is not
   the selected design and must never be disguised as a shared global model.

The formal 96-photo experiment and every break-even reachability verdict use
scope 2, the self-contained per-project archive. This scope is frozen before
results because the compressed archive is intended to be the only long-term
copy and must remain decodable without an external model repository.

The approved realistic project range for this contract is 93–300 photos, based
on the user-provided historical captures and product target. The formal point
is 96; 300 is the largest approved scope-2 reachability point.

Scope 1 is outside this experiment. It may be studied only under a separate
future design that proves permanent byte-identical model retention, offline
decode, cloud replication, version lookup, and failure recovery. Scope 1 must
not be selected after Phase 4 to rescue a scope-2 loss. Scope 3 is also outside
the formal design.

### Training checkpoint versus decoder model

Do not charge optimizer states, gradients, training-only master weights, or
dataset caches when the decoder does not need them. Conversely, do not omit a
runtime weight, lookup table, CDF buffer, quantization parameter, schema, or
custom operator artifact merely because it is packaged outside the `.ckpt`
file. The charged object is the exact canonical artifact set required to decode
the archive on a clean machine.

## Complete cost equation

```text
candidate_effective_bytes =
    pair_container_bytes
  + all_y_cb_cr_entropy_stream_bytes
  + exact_jpeg_reconstruction_side_bytes
  + cross_photo_reference_and_selector_bytes
  + index_manifest_checksum_bytes
  + ceil(model_stored_bytes * 2 / 96)
```

No byte may be omitted because it is shared, small, generated, cached, or
normally installed with the application. If the model is embedded in the pair
archive, it is counted once in persisted bytes and not charged again; the
result must explicitly prove where it was counted.

Formal admission requires:

```text
candidate_effective_bytes < jxl_a_archive_bytes + jxl_b_archive_bytes
```

Equality is failure. There is no additional 10% gate.

## Model break-even analysis

Let:

```text
J = jxl_a_archive_bytes + jxl_b_archive_bytes
B = complete candidate pair bytes before the amortized shared-model charge
M = minimum complete bytes among preregistered exact model-storage candidates
H = J - B
N = number of project photos sharing that one model
```

Then the candidate wins at scale `N` exactly when:

```text
B + ceil(2 * M / N) < J
```

Interpretation:

- If `H <= 0`, the coefficient/container stream already loses before model
  accounting. No larger project can rescue this exact candidate because model
  cost is non-negative.
- If `H == 1` and `M > 0`, no finite positive model charge can satisfy the
  strict inequality.
- If `H >= 2`, the smallest integer photo count at which the pair allocation
  fits is:

```text
N_break_even = ceil((2 * M) / (H - 1))
```

The implementation must verify this integer result by evaluating the exact
ceiling expression at `N_break_even - 1` and `N_break_even`.

It must also emit:

```text
break_even_reachable_under_approved_scope =
    N_break_even != null && N_break_even <= 300
```

When `N_break_even` is 97–300, the candidate is a formal loss at 96 but has a
reachable scale point inside the approved self-contained scope. When it exceeds
300, it is an unreachable loss under this contract. A mathematically defined
break-even at 1,000 or 10,000 is diagnostic only, not a positive verdict.

A reachable loss does not authorize the production encoder to switch codecs by
project photo count. Such an automatic internal policy is a separate product
decision with its own format-compatibility, recovery, and complexity review;
this research contract records the branch but grants no production authority.

`N_break_even` describes only fixed-model overhead. It is not permission to
extrapolate a two-photo stream ratio to a complete project. A later complete
project run must still encode every registered photo exactly once.

## Architecture

### Exact-JPEG container layer

Pin Google Brunsli v0.1 commit
`8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c`. Use its `ReadJpeg`,
`JPEGData`, and `WriteJpeg` paths to parse and reconstruct marker order,
quantization and Huffman tables, scans, restart state, padding, metadata,
inter-marker bytes, tail bytes, and component coefficient arrays.

The experiment adds a narrow adapter around the pinned source to serialize and
restore Brunsli's non-coefficient reconstruction sections separately from the
coefficient payload. It must not retain a full Brunsli coefficient stream next
to the PLR-derived coefficient stream, because that would duplicate the
dominant data.

The adapter is tested before any model training. Phase 0 also pins current
Brunsli master commit `c9128f43994c1ca830dd079777d85f16736d6ba7` as the only
allowed fallback. If unmodified v0.1 fails exact round-trip on either frozen
JPEG, do not patch, cherry-pick, or locally repair it. Run the same unmodified
Phase 1 test once on the pinned master commit and record the deviation. Use
master only if it passes every exactness and corruption gate. If v0.1 passes,
do not run master. If both pinned revisions fail, stop as
`blocked_upstream_exact_container`.

### PLR-derived entropy layer

The entropy layer encodes every quantized DCT coefficient for all components.
It uses a deterministic target-aware causal traversal in which encoder and
decoder derive the same distribution from already decoded target context.

- A is encoded with an intra-photo context model.
- B's conditional arm may use decoded A plus explicitly persisted geometry and
  selectors.
- The actual stored output is an integer-CDF rANS or arithmetic stream.
- Likelihood bpp without a complete serialized stream is invalid evidence.
- Learned CDF buffers are updated and stored before encoding.
- Any platform-specific floating-point step that can change decoder symbol
  decisions must be removed, quantized deterministically, or classified as an
  ARM64 portability blocker.

The Phase 2 decoder schedule is frozen at 22 ordered network distribution
stages per photo, derived as two hyperprior stages, two Cb/Cr checkerboard
stages, nine Y1 frequency-group stages, and nine combined Y2/Y3/Y4
frequency-group stages. The frequency grouping is
`[28, 8, 7, 6, 5, 4, 3, 2, 1]`, matching the official sibling implementation
used to complete the selected Trans path's missing initialization. The number
of stages is constant with image coefficient count. Per-coefficient
autoregression is forbidden; more than 24 stages is `blocked_portability`
before training.

The terminal encoder and decoder run in separate processes on CPU with one
fixed thread, deterministic algorithms, and no MPS/CUDA backend. Each process
emits the complete integer-CDF decision trace. Any trace difference invalidates
the arm even if a same-process round-trip happened to succeed.

### Pair envelope

The pair archive has a fixed version, model hash, source manifest hash,
component stream lengths, backward-only dependency list, SHA-256 values, and a
header checksum. B may depend on A; A may not depend on B. Corrupt, truncated,
missing-model, and missing-reference archives fail closed.

## H2 tuning boundary

Cross-photo conditioning is deliberately bounded because it is the least
established hypothesis.

- One preregistered intra-only arm is retained for attribution.
- One preregistered A-to-B conditional arm is the only H2 candidate.
- No search over alternate test pairs, block radii, coefficient cutoffs,
  reference trees, or hidden cost weights is allowed after terminal sizes are
  visible.
- If the conditional arm does not improve complete B bytes after all of its
  selectors and geometry are counted, H2 stops.
- A new H2 attempt requires a materially new, externally supported structural
  hypothesis and a new experiment contract. Parameter sweeping is not a new
  hypothesis.

H1 may still allow the full pair to beat JXL through stronger intra-photo
modeling. The report must separately attribute intra and conditional effects.

## Exactness and corruption gates

For both A and B:

- restored length equals the frozen source length;
- byte comparison succeeds;
- restored SHA-256 equals the frozen source SHA-256;
- all Y/Cb/Cr coefficient counts and values match before JPEG serialization;
- missing model, model-hash mismatch, missing A, truncated section, payload
  bit flip, and invalid section length are rejected before bytes are exposed.

The decoder may read only its declared backward dependency. Training data and
external caches are not decoder dependencies.

## Phase gates

1. **Phase 0 — identity, license, and model accounting:** freeze revisions,
   manifests, environment, canonical decoder-model serialization, parameter
   count, deployment precision, CDF-decision parity contract, the three fixed
   model-storage candidates, scope 2, the 93–300 approved range, both Brunsli
   revision hashes, and iPhone ARM64 operator inventory. Produce byte-exact
   model-storage round trips for the untrained frozen architecture; register
   its complete raw bytes as `provisional_model_raw_upper_bound_bytes`, while
   keeping provisional Zstd/ZPAQ sizes diagnostic. Establish the CDF-decision
   trace and parity harness. Record projected charges, but do not reject the
   model solely for exceeding an arbitrary byte ceiling. Freeze the two
   capture-wide exclusions, the experiment-local DVC pair, and the 22-stage
   decoder schedule before training. Stop on an unaccounted
   decoder dependency, an unregistered model serialization, or a CUDA-only
   decoding requirement.
2. **Phase 1 — Brunsli exact container:** extract non-coefficient state and raw
   coefficients, restore both source files, and pass corruption tests. Stop on
   any byte mismatch.
3. **Phase 2 — complete intra entropy codec:** serialize real Y/Cb/Cr streams
   for A and B independently, decode with updated CDF state, and restore both
   JPEGs. Run terminal exactness across separate one-thread CPU processes and
   require identical integer-CDF traces. Stop if any stream or decoder
   dependency is missing or the declared decoder exceeds 24 ordered stages.
4. **Phase 3 — bounded conditional arm:** run the single frozen A-to-B arm and
   the intra attribution arm. Stop H2 if its complete B bytes do not improve.
5. **Phase 4 — one terminal A/B:** because the exact-pair JXL baseline is
   currently absent, encode/decode each frozen input with JXL exactly once and
   persist both results. Reuse a hash-matching Lepton result or create each
   missing diagnostic result once. Rerun the frozen raw/Zstd/ZPAQ model-storage
   candidates and CDF-decision parity test on the final trained artifact, then
   select `final_M`. Create one formal candidate; apply the cost equation,
   exactness gates, and corruption gates; calculate `N_break_even`, reachability,
   and the registered scale-sensitivity rows; emit one terminal verdict. No
   provisional `M`, estimated `J`, or estimated `H` is permitted.

No later phase starts when an earlier phase fails.

## Terminal verdicts

- `winner_beats_jxl_and_lepton`
- `winner_beats_jxl_but_loses_lepton`
- `loser_at_formal_count_but_reachable_within_scope2`
- `loser_at_formal_count_break_even_unreachable_scope2`
- `loser_stream_before_model_accounting`
- `invalid_exactness_failure`
- `invalid_incomplete_cost_accounting`
- `blocked_portability`
- `blocked_upstream_or_license`
- `blocked_upstream_exact_container`

## Evidence requirements

Persist a versioned experiment contract, ordered input manifest and hashes,
Brunsli and PLR source identities, environment lock, model artifact/hash,
training exclusion proof, seeds, command, hardware/backend, byte accounting,
restored hashes, corruption outcomes, deviations, and terminal verdict.

DVC owns data and large model identity. MLflow owns run metadata and metrics.
`uv.lock` owns Python dependency identity. These records reference rather than
duplicate each other's source of truth.

## Non-goals

- No production encoder replacement.
- No phone bundle or device installation.
- No full PocketWorld project compression estimate derived from a winning pair.
- No claim that a paper's dataset result transfers to PocketWorld.
- No faithful-PLR, faithful-PLLR, or faithful-Microsoft-2016 label.
- No cross-project deduplication in the single-project compression metric.

## Authoritative local evidence

- `experiments/plr_official_natural_jpeg/upstream-audit.json`
- `experiments/plr_official_natural_jpeg/exact-jpeg-side-diagnostic.json`
- `experiments/plr_official_natural_jpeg/similar-jpeg-blockmatch-diagnostic.json`
- `experiments/lepton_jxl_iphone/results/2026-08-02-lepton-jxl-iphone-ab.json`
- `docs/research/2026-08-03-plr-community-exact-jpeg-audit.md`
