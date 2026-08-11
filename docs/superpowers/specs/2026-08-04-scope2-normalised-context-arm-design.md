# scope2_normalised_context — Follow-up Arm Design

## Status

Registered on 2026-08-04 while `scope2_compact` was mid-run at **epoch 8 of 20**
(6.5241 bits per coefficient, static floor not yet reached, no terminal verdict
written). This document is deliberately authored before that arm's terminal
result exists, so the hypothesis below cannot have been reverse-engineered from
its outcome.

This design authorises **one** additional arm. It is not an open parameter
sweep, and Section 9 fixes the point at which the intra-photo learned-entropy
hypothesis is abandoned rather than re-tried.

## 1. What this arm changes

Exactly one structural thing: **every raw coefficient tensor that flows into a
network as context is divided by the registered per-frequency prior; every raw
coefficient tensor that is a coding target is left untouched.**

Nothing else moves. See Section 7 for the frozen control variables.

## 2. Why — two evidenced defects with one shared cause

### Defect A — the network's input side is still unnormalised

`phase2-model-config.yaml` registers
`coefficient_value_transform: exact_float32_cast_without_normalization`.
Measured per-frequency standard deviation on frozen photo A spans **2964x**
(luma DC 490.4 down to 0.168 at the highest frequency); the training-split
measurement in `frequency-prior.json` independently reproduces this at 2964x
(329.17 down to 0.111).

Revision 1 of the entropy work fixed only the *output* side: the registered
prior initialises the scale half of each entropy-parameter head. That produced a
measured 33.2 percent improvement at initialisation (20.01 to 13.37 bits per
luma position on `scope2_compact`, validated before any gradient step). The
*input* side was left alone — `normalise_luma_context` and
`normalise_chroma_context` exist in `pw_plr/frequency_prior.py` but are not
wired into `base_eff.forward`.

Consequence: every convolution stack in `entropy_parameters`, `h_e_Y` and
`h_e_C` still consumes activations spanning three orders of magnitude.

### Defect B — the entropy bottleneck quantiles are not converging

`auxiliary_loss` on `scope2_compact` fell 0.357 percent per epoch over its first
four epochs and 0.674 percent per epoch over epochs 4 to 8. At the faster of the
two rates the quantiles need roughly 103 epochs to halve, against a registered
limit of 100. The same behaviour appeared on `official_width` (0.666 and 0.679
percent per epoch).

Mechanism: with `batch_size` 64 over 9,323 training photos there are about 146
optimiser steps per epoch, and Adam at `auxiliary_learning_rate` 1e-3 moves a
parameter on the order of 1e-3 per step, i.e. about 0.146 units of quantile
travel per epoch. CompressAI's default aux learning rate assumes latents of
order 1. Here the hyperprior latents derive from unnormalised DCT coefficients
of order hundreds, so the quantiles must travel far further than that default
was designed for.

**Correction to an earlier reading of this metric.** Defect B does *not* inflate
the training rate. CompressAI evaluates the training-time likelihood through
`_logits_cumulative`, which the main loss trains; `_quantiles` are used only by
`aux_loss` and by `update()` when it builds the discrete CDF tables. Defect B
therefore threatens the Phase 2 requirement for a real, independently decodable
integer-CDF stream, and does **not** explain the observed bits per coefficient.
The two defects are independent in their symptoms.

### The shared cause

Both defects trace to the same root: the model sees coefficients in their raw
domain. Normalising the network's *view* of the coefficients puts the conv
stacks on well-conditioned inputs (Defect A) and brings the hyperprior latents to
order 1, which is the regime the existing aux learning rate was designed for
(Defect B). One structural change, two predicted effects — which is what makes
this an arm rather than two parameter tweaks.

## 3. Exactness contract

Unchanged, and for the same reason as the Revision 1 prior.

`GaussianConditionalLatentCodec.forward(y, ctx_params)` computes
`gaussian_params = entropy_parameters(ctx_params)` and then
`gaussian_conditional(y, scales_hat, means=means_hat)`. The coding target `y`
never passes through `entropy_parameters`. This arm only rescales tensors on
their way into `entropy_parameters`, `h_e_Y` and `h_e_C`.

The coded alphabet, the integer CDF construction and the reconstructed
coefficients are unchanged in definition. Both frozen JPEG files must still
restore to their registered length, bytes and SHA-256, and every corruption gate
in the Phase 1 and Phase 2 contracts still applies unchanged.

### Prior applied on both sides, in opposite directions

The same registered 192-value table is used twice, and the directions must not
be confused:

- **Input side (new in this arm):** context is divided by the prior, so the
  network sees order-1 values.
- **Output side (already shipped):** the scale-head bias is initialised *to* the
  prior, because the predicted sigma must live in the raw coefficient domain —
  the target it describes is raw.

## 4. Exactly where the transform applies

In `EfficientJPEGRecompression`, raw coefficient tensors appear in both roles.
The rule is mechanical: context divided, target untouched.

| Site | Role | Action |
|---|---|---|
| `hyper_cbcr(CbCr)` | hyperprior input | divide |
| `hyper_Y(cat(Y1, Y2, Y3, Y4))` | hyperprior input | divide |
| `Guassian_cbcr_anchor(CbCr_anchor, h_cbcr)` | `CbCr_anchor` is target; `h_cbcr` is a network output | no change |
| `Guassian_cbcr_non_anchor(CbCr_non_anchor, cat(h_cbcr, CbCr_anchor))` | `CbCr_non_anchor` target; `CbCr_anchor` context | divide the context copy only |
| `Gaussion_Ys[i](Y1_f[i], cat(h_y, *Y1_f[:i]))` | `Y1_f[i]` target; `Y1_f[:i]` context | divide the context copies only |
| `prior_input = cat(h_y, Y1)` | context | divide |
| `Gaussion_Ys_234[i](cat(Y2_f[i], Y3_f[i], Y4_f[i]), cat(prior_output, *Y2_f[:i], *Y3_f[:i], *Y4_f[:i]))` | first argument target; the rest context | divide the context copies only |

`normalise_luma_context` already refuses any tensor whose channel count is not a
whole multiple of 64. Coding targets are frequency *groups* of 28, 8, 7, 6, 5, 4,
3, 2 or 1 channels, so an accidental call on a target fails loudly rather than
silently corrupting the alphabet. Section 8 keeps a test on that guard.

## 5. Decoder reproducibility

The decoder must derive bit-identical context. It can:

- every divided tensor is either a hyperprior input the decoder reconstructs, or
  a coefficient group that is already fully decoded at that point in the
  registered 22-stage schedule;
- the divisor is a registered constant table shipped inside the model artifact,
  not a value derived from undecoded data;
- `decoder_sequential_passes` stays 22 and the dependency order is unchanged.

The patch must be applied to `forward`, `compress` and `decompress` alike. A
patch that changes only `forward` would train against one context distribution
and decode against another; Section 8 gates on this explicitly.

## 6. Deviation from pinned upstream — declared

The Revision 1 change touched only initialisation and needed no upstream edit.
This arm edits `compressai/models/base_eff.py` in all three of `forward`,
`compress` and `decompress`, so it is a larger deviation surface than the
existing `plr-exact-22-stage.patch`.

It must be registered as its own patch with its own SHA-256 in
`phase2-model-config.yaml` under `upstream`, and it must appear in
`_implementation_identity` so the trained-model identity moves with it. The arm
remains a `PLR-derived completion` and must not be described as official PLR.

## 7. Frozen control variables

Everything below is byte-identical to the `scope2_compact` control arm. The
comparison is worthless otherwise.

- corpus `phase2-combined-corpus.json`, content identity
  `f0f1c309a4237da178c1e5e752ec8b522e2e5a44195187e32649a066a55e2b75`
- the same train / validation / diagnostic split and the same seed `20260803`
- capture exclusions `analysis_cap_1779777762841797` and its `_v2`
- `N = 96`, `M = 144`, `frequency` groups `[28, 8, 7, 6, 5, 4, 3, 2, 1]`
- `main_learning_rate` 1e-4 and `auxiliary_learning_rate` 1e-3 — **unchanged on
  purpose.** The hypothesis is that normalisation makes the existing aux rate
  adequate. Changing the rate at the same time would make a passing result
  unattributable.
- `batch_size` 64, `microbatch_size` 8, `gradient_clip_max_norm` 1.0
- `frequency-prior.json`, unchanged table and unchanged corpus identity
- static floor 1.471 bits per coefficient, `patience_epochs` 20
- frozen pair, its SHA-256 values, and the measured `J` of 5,012,613 bytes
- scope 2, `N = 96` project denominator, `ceil(2M / 96)` model charge

`scope2_compact` is the control arm. One variable moves.

## 8. Preregistered predictions

Stated before the arm runs, so a miss is recorded as a miss.

1. **Rate.** Epoch 0 lands below the control arm's 13.2018 bits per luma
   position. A result at or above the control refutes the conditioning
   explanation for Defect A outright.
2. **Aux convergence.** `auxiliary_loss` falls materially faster than the
   control's 0.357 to 0.674 percent per epoch. If it still crawls under 1 percent
   per epoch, the "latents start far from the quantile initialisation"
   explanation for Defect B is **refuted** and must be recorded as such, whatever
   the rate does. This is the load-bearing mechanistic claim of the arm.
3. **Floor.** The arm clears 1.471 bits per coefficient before epoch 20.

Prediction 3 is the gate. Predictions 1 and 2 are recorded either way, because
an arm that clears the floor while refuting its own stated mechanism is a result
that needs saying out loud rather than quietly banking.

## 9. Stop rule

If this arm also fails the static floor, **stop**. The verdict is then that the
intra-photo learned entropy model at this scale, on this corpus, in this
implementation, does not reach a free 192-entry histogram baseline — and by the
existing contract that forbids a third arm without a materially new, externally
supported structural hypothesis. Another implementation defect found afterwards
does not by itself qualify: at two arms the accumulated evidence is about the
approach as executed here, not about one configuration.

Falling back is not a loss of the project. The measured incumbent stands:
Lepton at 4,964,104 bytes on the frozen pair, byte-exact, zero model bytes,
Apache-2.0, already carrying 111 of the 155 photos in the 467,413,773-byte
semantic archive.

## 10. Test gates before the arm may launch

1. Context-versus-target separation: applying the patch changes no coding target
   tensor, asserted by comparing every target tensor with and without the
   transform.
2. `forward`, `compress` and `decompress` all apply the identical transform,
   asserted by a shared helper rather than three hand-written copies.
3. The `normalise_luma_context` group-size guard still rejects a partial
   sub-band, so a target call cannot pass silently.
4. Encode and decode in separate CPU processes at one thread produce identical
   integer CDF traces on a small fixture, per the registered terminal
   determinism contract.
5. Both frozen JPEG files still round-trip to their registered SHA-256.

Gate 5 is not optional even though this arm is about training: an entropy change
that cannot restore the frozen pair has already failed the only thing the whole
experiment is for.

## 11. Authoritative evidence

- `experiments/plr_derived_brunsli_two_photo/results/jxl-frozen-pair-baseline.json`
- `experiments/plr_derived_brunsli_two_photo/results/rate-target-derivation.json`
- `experiments/plr_derived_brunsli_two_photo/results/phase1-v0.1.json`
- `experiments/plr_derived_brunsli_two_photo/frequency-prior.json`
- `experiments/plr_derived_brunsli_two_photo/results/phase2-training/scope2_compact/epochs.jsonl`
- `experiments/plr_derived_brunsli_two_photo/results/phase2-training/official_width/epochs.jsonl`
