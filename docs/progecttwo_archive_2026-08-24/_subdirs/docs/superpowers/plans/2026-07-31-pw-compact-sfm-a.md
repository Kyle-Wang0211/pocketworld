# PocketWorld Compact SfM A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan task-by-task. The user
> explicitly prohibited subagents, so execution remains inline. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine on a real iPhone whether a canonical, logically bit-exact
SfM store can beat raw-SQLite ZPAQ method 5 by at least 10% while retaining
bounded random reads and identical reconstruction output.

**Architecture:** Start with an intentionally optimistic whole-stream host
screen: known-schema SQLite values are serialized column-wise and compressed as
one ZPAQ stream, with no random-access chunk overhead. Failure there rejects the
design before a full codec. Only a passing arm advances to a portable C++17
chunked container and an isolated iPhone benchmark bundle; production remains
untouched.

**Tech Stack:** Python 3 standard library for the disposable potential
estimator, C++17 for the portable accepted codec, SQLite C API, pinned libzpaq
7.15 method 5, CMake/CTest, SHA-256, physical iPhone isolated test bundle.

---

### Task 1: Freeze the experiment and validate the 50 MB source

**Files:**

- Create: `experiments/pw_compact_sfm_a/experiment-contract.yaml`
- Create: `experiments/pw_compact_sfm_a/input-manifest.yaml`
- Create: `experiments/pw_compact_sfm_a/README.md`

- [ ] **Step 1: Record the source identity and gates**

Copy the 50,008,064-byte input identity from the accepted manifest. Record raw
ZPAQ method 5 as the baseline, `candidate_bytes <= baseline_bytes * 0.90` as
the host continuation threshold, and zero logical mismatch as a hard gate.

- [ ] **Step 2: Verify the immutable source**

Run:

```bash
shasum -a 256 \
  /private/tmp/pwcsfma-input-20260731/cap_1785297411166420/official_sfm_live.db
```

Expected:

```text
d71b3c54843ae3b25cb2269e723a0c33612a4a2bade08ff97f85a6108ce0bfe7
```

- [ ] **Step 3: Verify schema and integrity read-only**

Run:

```bash
sqlite3 -readonly \
  /private/tmp/pwcsfma-input-20260731/cap_1785297411166420/official_sfm_live.db \
  "PRAGMA integrity_check; SELECT count(*) FROM descriptors;"
```

Expected: `ok` and `37`.

### Task 2: Build the pinned ZPAQ baseline executable through TDD

**Files:**

- Create: `experiments/pw_compact_sfm_a/native/zpaq_file_cli.cpp`
- Create: `experiments/pw_compact_sfm_a/tests/test_zpaq_cli.py`
- Create: `experiments/pw_compact_sfm_a/run_tests.sh`

- [ ] **Step 1: Write a failing round-trip test**

The test creates a deterministic 1 MiB source, invokes:

```text
zpaq_file_cli compress source archive
zpaq_file_cli decompress archive restored
```

and requires `restored == source`, a smaller archive, version `7.15`, and the
pinned bridge revision.

- [ ] **Step 2: Run RED**

Run:

```bash
bash experiments/pw_compact_sfm_a/run_tests.sh
```

Expected: fail because `native/zpaq_file_cli.cpp` does not exist.

- [ ] **Step 3: Implement the minimal CLI**

Compile the existing read-only production files:

```text
/Users/kaidongwang/Developer/pocketworld/ios/Runner/pw_zpaq_bridge.cpp
/Users/kaidongwang/Developer/pocketworld/ios/Vendor/Zpaq/src/libzpaq.cpp
```

The CLI only validates arguments and calls `pw_zpaq_compress_file` or
`pw_zpaq_decompress_file` with method 5 and the current cancellation generation.

- [ ] **Step 4: Run GREEN**

Run the same test command. Expected: `PWCSFMA_ZPAQ_TEST_OK`.

### Task 3: Define and test the logical dataset digest

**Files:**

- Create: `experiments/pw_compact_sfm_a/pwcsfma/logical.py`
- Create: `experiments/pw_compact_sfm_a/tests/test_logical.py`

- [ ] **Step 1: Write failing deterministic-digest tests**

Create two SQLite fixtures containing every COLMAP table and values that cover
NULL, empty BLOB, non-empty BLOB, negative/positive integers, text, and exact
float BLOB bits. Require identical logical data created through different SQL
insertion orders to have the same digest, while any value or declared row-order
change changes the digest.

- [ ] **Step 2: Run RED**

Run:

```bash
python3 -m unittest \
  experiments.pw_compact_sfm_a.tests.test_logical -v
```

Expected: import failure for `pwcsfma.logical`.

- [ ] **Step 3: Implement canonical typed hashing**

Serialize table name, column name, SQLite storage class, value length, and value
bytes. Read each known table in explicit primary-key order. BLOBs are hashed as
bytes; integers use signed little-endian 64-bit; text uses UTF-8; NULL has its
own type tag.

- [ ] **Step 4: Run GREEN**

Expected: deterministic digest tests pass.

### Task 4: Implement the optimistic normalized stream through TDD

**Files:**

- Create: `experiments/pw_compact_sfm_a/pwcsfma/varint.py`
- Create: `experiments/pw_compact_sfm_a/pwcsfma/optimistic_stream.py`
- Create: `experiments/pw_compact_sfm_a/tests/test_optimistic_stream.py`

- [ ] **Step 1: Write failing exact round-trip tests**

Fixtures must cover:

- `N × 6` keypoints with exact float32 bit patterns, including NaN payloads;
- `N × 128` descriptor bytes;
- raw matches whose order is not sorted;
- duplicate raw matches;
- two-view matches that reference different duplicate occurrences;
- literal two-view exceptions;
- NULL versus empty matrix BLOBs.

Encode then decode and compare the complete in-memory logical rows and logical
digest.

- [ ] **Step 2: Run RED**

Run:

```bash
python3 -m unittest \
  experiments.pw_compact_sfm_a.tests.test_optimistic_stream -v
```

Expected: import failure for `pwcsfma.optimistic_stream`.

- [ ] **Step 3: Implement reversible transforms**

Implement:

- unsigned LEB128 and signed zig-zag varints;
- descriptor transpose and inverse;
- keypoint column split plus per-column byte shuffle and inverse;
- order-preserving match endpoint deltas and inverse;
- occurrence-aware two-view references plus literal exceptions;
- typed metadata encoding.

Do not add quantization, sorting, row deletion, or float arithmetic.

- [ ] **Step 4: Run GREEN**

Expected: all fixture digests and values match exactly.

### Task 5: Run the 50 MB optimistic host continuation screen

**Files:**

- Create: `experiments/pw_compact_sfm_a/run_potential.py`
- Create: `experiments/pw_compact_sfm_a/results/.gitkeep`

- [ ] **Step 1: Encode and verify the source**

Run:

```bash
python3 experiments/pw_compact_sfm_a/run_potential.py \
  --input /private/tmp/pwcsfma-input-20260731/cap_1785297411166420/official_sfm_live.db \
  --output-dir /private/tmp/pwcsfma-host-screen
```

The command must:

1. verify source SHA-256 and `PRAGMA integrity_check`;
2. compute the source logical digest;
3. write and decode the optimistic normalized stream;
4. require decoded logical digest equality;
5. compress/decompress raw SQLite and normalized stream with the pinned CLI;
6. require both decompressed files to match their respective sources;
7. emit one durable JSON result containing bytes, hashes, elapsed time, peak
   RSS, and verdict.

- [ ] **Step 2: Apply the pre-registered stop rule**

Continue only when:

```text
normalized_zpaq_bytes <= raw_sqlite_zpaq_bytes * 0.90
```

Because this arm has more favorable compression conditions than the required
random-access format, failure rejects `PWCSFMA1` before phone work.

### Task 6: Build the portable chunked C++ core only after a host pass

**Files:**

- Create: `experiments/pw_compact_sfm_a/native/pwcsfma_codec.h`
- Create: `experiments/pw_compact_sfm_a/native/pwcsfma_codec.cpp`
- Create: `experiments/pw_compact_sfm_a/native/pwcsfma_sqlite.cpp`
- Create: `experiments/pw_compact_sfm_a/native/pwcsfma_zpaq.cpp`
- Create: `experiments/pw_compact_sfm_a/native/pwcsfma_codec_test.cpp`
- Create: `experiments/pw_compact_sfm_a/CMakeLists.txt`

- [ ] **Step 1: Port fixture tests before implementation**

Require deterministic archive identity, exact decode, wrong-version rejection,
truncation/bit-flip rejection, feature random reads bounded to eight images,
and pair random reads bounded to 256 pairs.

- [ ] **Step 2: Implement the minimal chunked format**

Port the accepted transforms to bounded C++17 code, independently ZPAQ-compress
each chunk, and write an authenticated offset/length/hash index.

- [ ] **Step 3: Add SQLite export**

Create a new database from the pinned schema, insert all decoded rows in
canonical order inside one transaction, run `PRAGMA integrity_check`, and
compare logical digests.

- [ ] **Step 4: Run CTest**

Run:

```bash
cmake -S experiments/pw_compact_sfm_a \
  -B /private/tmp/pwcsfma-build \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /private/tmp/pwcsfma-build
ctest --test-dir /private/tmp/pwcsfma-build --output-on-failure
```

Expected: all tests pass.

### Task 7: Run all frozen host diagnostics

**Files:**

- Create: `experiments/pw_compact_sfm_a/run_host_matrix.py`
- Update: `experiments/pw_compact_sfm_a/results/host-results.jsonl`

- [ ] **Step 1: Run all five inputs for three repeats**

Persist every result before the next run. Verify deterministic container and
archive identities and preserve failed results.

- [ ] **Step 2: Apply host rejection gates**

Reject if any exactness check fails, any candidate is larger than raw ZPAQ, or
median improvement is below 10%.

### Task 8: Build and run the isolated physical-iPhone bundle

**Files:**

- Create:
  `experiments/pw_compact_sfm_a/ios/PWCSFMABench.xcodeproj/project.pbxproj`
- Create: `experiments/pw_compact_sfm_a/ios/PWCSFMABench/Info.plist`
- Create: `experiments/pw_compact_sfm_a/ios/PWCSFMABench/main.mm`
- Create:
  `experiments/pw_compact_sfm_a/ios/PWCSFMABench/PWCSFMABenchAppDelegate.h`
- Create:
  `experiments/pw_compact_sfm_a/ios/PWCSFMABench/PWCSFMABenchAppDelegate.mm`
- Update: `experiments/pw_compact_sfm_a/results/phone-results.jsonl`

- [ ] **Step 1: Use a non-production identifier**

The bundle identifier must not be `com.kyle.PocketWorld`, and its container must
have no entitlement or path to the production app container.

- [ ] **Step 2: Run three repeats per input**

Transfer one verified copy at a time, compare raw ZPAQ and candidate using the
same C++ core, and persist result JSON after every arm.

- [ ] **Step 3: Verify random reads and faults**

Randomly select image IDs and pair IDs from a fixed seed. Verify exact values,
chunk bounds, bit-flip/truncation rejection, interruption cleanup, and restart.

- [ ] **Step 4: Verify actual pipeline parity**

On isolated capture copies, run baseline SQLite and candidate-exported SQLite
through the actual production finalize path. Require the declared PLY, poses,
counts, registrations, and summaries to be identical.

- [ ] **Step 5: Issue the only allowed verdict**

- `accept-for-separate-production-design`: zero correctness failures, no
  per-input regression, and at least 10% lower median bytes across three phone
  repeats;
- otherwise `reject-keep-raw-zpaq`.

No production installation or archive change occurs in this plan.
