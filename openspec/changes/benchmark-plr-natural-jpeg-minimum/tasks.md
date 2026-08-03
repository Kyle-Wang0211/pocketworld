## 1. Freeze identities and gates

- [x] 1.1 Freeze the PocketWorld repository state, official PLR commit/tree and
  source hashes, one-JPEG identity, saved same-input JXL result, metrics,
  amortization denominator, and stop conditions.
- [x] 1.2 Stop expansion of the old cross-photo predictor and forbid production
  or phone changes.

## 2. Audit the official public implementation

- [x] 2.1 Inspect the official training entry for actual entropy encode/decode
  and archive serialization.
- [x] 2.2 Inspect input handling and output reconstruction for arbitrary original
  JPEG markers, headers, metadata, coefficients, length, bytes, and SHA-256.
- [x] 2.3 Inspect the selected model's public `compress/decompress` attributes,
  public checkpoints, tags, and release assets.

## 3. Execute only if preflight passes

- [x] 3.1 Stop condition triggered: official public revision has no executable
  complete exact-JPEG codec, so no large environment or dataset was installed.
- [ ] 3.2 Train/adapt one fixed global model on natural photos. Blocked by 3.1;
  running it would yield only estimated rate under the public route.
- [ ] 3.3 Encode/decode the registered PocketWorld JPEG and verify every source
  byte and SHA-256. Blocked by 3.1 because no public JPEG file reconstruction
  route exists.
- [ ] 3.4 Count complete stream and model amortization and compare with saved
  JXL. Blocked by 3.1 because no valid PLR stream can be produced.

## 4. Scale-up decision

- [x] 4.1 Leave cross-photo conditioning, complete-project testing, production,
  and phone work stopped. This is an implementation-completeness rejection, not
  evidence that the PLR model's compression performance loses.
