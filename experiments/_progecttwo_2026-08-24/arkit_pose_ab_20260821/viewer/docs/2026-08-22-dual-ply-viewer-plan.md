# A / B1 Dual PLY Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and open a local, interactive, side-by-side WebGL viewer for the exact A and B1 raw sparse reconstructions.

**Architecture:** A Python build script validates the frozen COLMAP models and exact 60-frame capture HEVC, decodes those frames, extracts mean track-observation RGB with pycolmap, computes B1→A camera-center Sim(3), exports two unfiltered true-color ASCII PLY files, and emits a self-contained Plotly page plus provenance manifest. A separate verifier parses the generated PLY/header/manifest/HTML without modifying them.

**Tech Stack:** Python 3.11, pycolmap 4.0.4, NumPy 2.4.6, Plotly 6.8.0, browser WebGL, local HTTP server.

---

### Task 1: Write the output contract test

**Files:**
- Create: `viewer/tests/verify_viewer.py`

- [ ] Parse ASCII PLY headers and assert A/B vertex counts are exactly `20407/20348`.
- [ ] Load `viewer-manifest.json`; assert source model hashes, counts, `filtering=false`, B1 alignment label, and PLY hashes.
- [ ] Assert `index.html` contains both PLY filenames, both arm labels, camera-sync handler, no `http://` or `https://` dependency, and the audited quality labels.
- [ ] Before implementation run:

```bash
/opt/homebrew/bin/python3.11 viewer/tests/verify_viewer.py
```

Expected: nonzero exit because generated artifacts do not exist.

### Task 2: Build the PLY exporter and viewer generator

**Files:**
- Create: `viewer/build_viewer.py`
- Generate: `viewer/data/A_raw_same_graph.ply`
- Generate: `viewer/data/B1_raw_aligned_to_A.ply`
- Generate: `viewer/viewer-manifest.json`
- Generate: `viewer/index.html`

- [ ] Assert frozen `cameras.bin`, `images.bin`, and `points3D.bin` hashes before reading.
- [ ] Load A/B reconstructions and assert 20,407/20,348 points and 59/57 registered images.
- [ ] Compute B1→A Sim(3) with `pycolmap.align_reconstructions_via_proj_centers(..., 0.1)` and assert scale within `1e-12` of `0.167374037472674`.
- [ ] Decode the frozen 60-frame HEVC to lossless PNG pixels, verify exact frame/name mapping, and run pycolmap's standard mean-over-track-observations color extraction for both arms.
- [ ] Write every point exactly once to ASCII PLY; preserve coordinates, extracted true RGB, track length, and reprojection error. Do not generate any pseudocolor.
- [ ] Generate a local-only HTML page that fetches both PLYs, renders two equal Plotly 3D scenes, synchronizes cameras, and exposes point-size/reset/fullscreen controls.
- [ ] Run:

```bash
/opt/homebrew/bin/python3.11 viewer/build_viewer.py
```

Expected: `BUILT A=20407 B1=20348` and four generated artifacts.

### Task 3: Make the contract green

- [ ] Run the verifier:

```bash
/opt/homebrew/bin/python3.11 viewer/tests/verify_viewer.py
```

Expected: `PASS viewer contract A=20407 B1=20348`.

- [ ] Re-run the builder and verifier; assert manifest and PLY SHA values are deterministic.

### Task 4: Browser acceptance

- [ ] Start an HTTP server rooted at `viewer/` on a loopback-only port.
- [ ] Open `index.html` in the available browser.
- [ ] Confirm the page title, both labels, and two plotted point clouds are visible.
- [ ] Change point size and orbit one panel; confirm the other camera follows while sync is enabled.
- [ ] Capture a screenshot and inspect it for clipping, blank panels, illegible labels, or generic dashboard clutter.
- [ ] Check browser console errors and HTTP status for `index.html` and both PLYs; all must pass.
