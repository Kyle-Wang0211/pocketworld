# PLR-Derived Brunsli Two-Photo Exact-JPEG Design

## Status

Approved for Mac-only research execution on 2026-08-03. This approval does not
assert that learned JPEG recompression will win. It approves a bounded
experiment that can produce a valid winner, loser, invalid, or blocked verdict.

Revision 1 removes the proposed 15–20 MB hard model-size ceiling. Model size is
now governed by complete byte accounting and an explicit break-even project
scale. This keeps the 141-photo formal gate unchanged while avoiding the false
conclusion that a fixed model which loses on a small project must also lose on a
large project.

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

The two files are excluded from model training, model selection, validation
selection, and parameter tuning.

## Frozen baselines

### Formal acceptance baseline

The formal baseline is the sum of the two same-input libjxl 0.12.0
exact-JPEG, effort-10 archive sizes.

- Reuse saved, hash-matching results when present.
- If a same-input result does not exist, run each JXL encode/decode exactly once
  and persist the result identity permanently.
- Never rerun the baseline for stability. Encoded byte size is deterministic
  evidence, not a noisy timing metric.

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

There is no fixed 15 MB, 20 MB, or other absolute rejection threshold. A fixed
model is constant overhead while project data grows. An absolute ceiling would
incorrectly reject a larger model that may create more than enough stream
savings on a large project.

The formal experiment continues to use `141` photos because that is the frozen
project scale. The two-photo model charge remains:

```text
formal_pair_model_charge = ceil(model_stored_bytes * 2 / 141)
```

At complete 141-photo project scale, the same accounting adds the model exactly
once. The pair formula is an allocation of that one shared model, not a claim
that the archive stores 2/141 of a physical file.

The result must also report model-overhead sensitivity for photo counts
`2`, `44`, `141`, `1,000`, and `10,000`, plus the actual count of any later
project. Only `141` determines this experiment's formal verdict. Other counts
explain scale behavior and do not move the frozen gate.

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

The formal 141-photo experiment uses scope 2, the conservative self-contained
project case. A later production design may use scope 1 only if global model
availability, versioning, offline decode, cloud retention, and hash identity
are guaranteed. Scope 1 must not be used retroactively to make this experiment
look smaller.

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
  + ceil(model_stored_bytes * 2 / 141)
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
M = canonical stored decoder-model bytes
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

Example: a 60 MB shared model is not automatically rejected. Its two-photo
charge is about 851 KB at 141 photos, 120 KB at 1,000 photos, and 12 KB at
10,000 photos. Whether it wins is decided by the actual stream headroom `H`,
not by the number 60 MB in isolation.

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

The adapter is tested before any model training. A failure to round-trip either
frozen JPEG stops the experiment.

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
   count, storage scope, and iPhone ARM64 operator inventory. Record the model
   size and projected charges, but do not reject it solely for exceeding an
   arbitrary byte ceiling. Stop only on an unaccounted decoder dependency or a
   CUDA-only decoding requirement.
2. **Phase 1 — Brunsli exact container:** extract non-coefficient state and raw
   coefficients, restore both source files, and pass corruption tests. Stop on
   any byte mismatch.
3. **Phase 2 — complete intra entropy codec:** serialize real Y/Cb/Cr streams
   for A and B independently, decode with updated CDF state, and restore both
   JPEGs. Stop if any stream or decoder dependency is missing.
4. **Phase 3 — bounded conditional arm:** run the single frozen A-to-B arm and
   the intra attribution arm. Stop H2 if its complete B bytes do not improve.
5. **Phase 4 — one terminal A/B:** read saved JXL and diagnostic Lepton
   baselines; create one formal candidate; apply the cost equation, exactness
   gates, and corruption gates; calculate `N_break_even` and the registered
   scale-sensitivity rows; emit one terminal verdict.

No later phase starts when an earlier phase fails.

## Terminal verdicts

- `winner_beats_jxl_and_lepton`
- `winner_beats_jxl_but_loses_lepton`
- `loser_complete_but_not_smaller_than_jxl`
- `loser_at_141_but_scale_break_even_defined`
- `loser_stream_before_model_accounting`
- `invalid_exactness_failure`
- `invalid_incomplete_cost_accounting`
- `blocked_portability`
- `blocked_upstream_or_license`

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
