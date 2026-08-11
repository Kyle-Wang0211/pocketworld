## 1. Contract

- [x] 1.1 Freeze input, baseline, dependency identities, parameters, metrics,
  stopping rules, DVC reference, and MLflow experiment.
- [x] 1.2 Add contract tests that prohibit production and phone commands.

## 2. Common exact archive

- [x] 2.1 Add failing tests for group manifests, modulo-65536 residuals,
  corruption rejection, and exact child reconstruction.
- [x] 2.2 Implement the common group payload and benchmark-only ZPAQ CLI.
- [x] 2.3 Verify roots and synthetic children restore byte-for-byte.

## 3. Arm A

- [x] 3.1 Add failing dense-flow grid and local-selector tests.
- [x] 3.2 Implement the OpenCV dense-flow helper and local DCT forest.
- [x] 3.3 Run all 25 JPEGs once, restore all 25, and persist complete bytes.

## 4. Arm B

- [x] 4.1 Add failing earlier-parent and parent-map tests.
- [x] 4.2 Implement the Faiss DCT block forest helper.
- [x] 4.3 Run all 25 JPEGs once, restore all 25, and persist complete bytes.

## 5. Arm C and decision

- [x] 5.1 Record official revision, license/model terms, and executability.
- [x] 5.2 Run C only if all commercial and reproducibility gates pass; otherwise
  persist a `blocked-license` result with primary evidence.
- [x] 5.3 Compare complete A/B/C results with JXL, record the winner in MLflow,
  and remove large temporary artifacts.

## 6. Future candidate admission

- [x] 6.1 Freeze the complete two-photo -> eight-photo -> 100-MiB funnel.
- [x] 6.2 Require strict size wins plus exactness at every promotion stage.
