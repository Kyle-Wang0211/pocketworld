#!/usr/bin/env python3
"""pwofficial_gpu_match_guided_fixtures.py — builds guided-matcher fixtures.

Two sources, one on-disk format:

  real   : every two_view_geometries row of a capture session db (COLMAP
           schema), replicating official_aether_sfm_c.cc PrepareGuidedGeometry
           verbatim: CALIBRATED(2)/CALIBRATED_RIG(7) with E → mode 1 on
           normalised camera coordinates, max_residual = (0.5·(thr_a+thr_b))²
           with thr = 4.0 px / mean focal length (Camera::CamFromImgThreshold);
           UNCALIBRATED(3) with F → mode 1 on pixels, residual 16.0;
           PLANAR/PANORAMIC/PLANAR_OR_PANORAMIC(4/5/6) with H → mode 2 on
           pixels, residual 16.0, matrix_ba = H⁻¹. Descriptors come from the
           full-gate frame library (frames_<db>/f<image_id>/a.u8).
  probe  : synthetic pairs whose candidate keypoints are placed AT the
           residual threshold (nom²/denom = maxResidual·(1 ± eps) with eps in
           {0, 1e-6, 1e-4, 1e-2}) so the boundary-divergence claim is tested
           head-on, plus a random-descriptor body so top-2 competition is real.

Fixture dir: a.u8 b.u8 manifest.json (H2 contract) + xy_a.f32 xy_b.f32
(float32 x,y per row) + mat_ab.f32 mat_ba.f32 (9 float32 row-major) +
guided.json {"mode","max_residual","ratio","source",...}.
"""
import hashlib
import json
import os
import sqlite3
import struct
import sys

import numpy as np

MAX_ERROR_PIXELS = 4.0
RATIO = 0.8  # kSpatialMatchRatio
MAX_IMAGE_ID = 2147483647


def sha(b):
    return hashlib.sha256(b).hexdigest()


def write_fixture(d, a_u8, b_u8, xy_a, xy_b, m_ab, m_ba, mode, res, meta):
    os.makedirs(d, exist_ok=True)
    a_u8 = np.ascontiguousarray(a_u8, dtype=np.uint8)
    b_u8 = np.ascontiguousarray(b_u8, dtype=np.uint8)
    open(os.path.join(d, "a.u8"), "wb").write(a_u8.tobytes())
    open(os.path.join(d, "b.u8"), "wb").write(b_u8.tobytes())
    json.dump({"rows_a": int(a_u8.shape[0]), "rows_b": int(b_u8.shape[0]),
               "sha256_a": sha(a_u8.tobytes()), "sha256_b": sha(b_u8.tobytes()),
               "cols": 128}, open(os.path.join(d, "manifest.json"), "w"))
    np.ascontiguousarray(xy_a, dtype=np.float32).tofile(os.path.join(d, "xy_a.f32"))
    np.ascontiguousarray(xy_b, dtype=np.float32).tofile(os.path.join(d, "xy_b.f32"))
    np.ascontiguousarray(m_ab, dtype=np.float32).reshape(9).tofile(os.path.join(d, "mat_ab.f32"))
    np.ascontiguousarray(m_ba, dtype=np.float32).reshape(9).tofile(os.path.join(d, "mat_ba.f32"))
    meta = dict(meta)
    meta.update({"mode": int(mode), "max_residual": float(res), "ratio": RATIO})
    json.dump(meta, open(os.path.join(d, "guided.json"), "w"), indent=1)


def real_fixtures(db_path, frames_dir, out_root, limit=None):
    con = sqlite3.connect(db_path)
    cams = {}
    for cid, model, w, h, params in con.execute(
            "select camera_id, model, width, height, params from cameras"):
        p = np.frombuffer(params, dtype=np.float64)
        if model == 1:      # PINHOLE fx fy cx cy
            fx, fy, cx, cy = p[:4]
        elif model == 0:    # SIMPLE_PINHOLE f cx cy
            fx = fy = p[0]; cx, cy = p[1], p[2]
        else:
            raise SystemExit(f"unsupported camera model {model} (only pinhole replicated)")
        cams[cid] = (fx, fy, cx, cy)
    img_cam = dict(con.execute("select image_id, camera_id from images"))
    kps = {}
    for iid, rows, cols, data in con.execute("select image_id, rows, cols, data from keypoints"):
        arr = np.frombuffer(data, dtype=np.float32).reshape(rows, cols)
        kps[iid] = arr[:, :2].copy()
    n_written = 0
    stats = {"mode1_E": 0, "mode1_F": 0, "mode2_H": 0, "skipped": 0}
    for pair_id, config, F, E, H in con.execute(
            "select pair_id, config, F, E, H from two_view_geometries order by pair_id"):
        i1 = pair_id // MAX_IMAGE_ID
        i2 = pair_id % MAX_IMAGE_ID
        fa = os.path.join(frames_dir, f"f{i1}", "a.u8")
        fb = os.path.join(frames_dir, f"f{i2}", "a.u8")
        if not (os.path.exists(fa) and os.path.exists(fb) and i1 in kps and i2 in kps):
            stats["skipped"] += 1
            continue
        a = np.fromfile(fa, dtype=np.uint8).reshape(-1, 128)
        b = np.fromfile(fb, dtype=np.uint8).reshape(-1, 128)
        xa, xb = kps[i1], kps[i2]
        if a.shape[0] != xa.shape[0] or b.shape[0] != xb.shape[0]:
            # the frame library is the 8192-clamped table; keypoints table must agree
            n = min(a.shape[0], xa.shape[0]); a, xa = a[:n], xa[:n]
            n = min(b.shape[0], xb.shape[0]); b, xb = b[:n], xb[:n]
        mat = lambda blob: np.frombuffer(blob, dtype=np.float64).reshape(3, 3)
        if config in (2, 7) and E is not None and len(E) == 72:
            fxa, fya, cxa, cya = cams[img_cam[i1]]
            fxb, fyb, cxb, cyb = cams[img_cam[i2]]
            na = np.stack([(xa[:, 0] - cxa) / fxa, (xa[:, 1] - cya) / fya], 1)
            nb = np.stack([(xb[:, 0] - cxb) / fxb, (xb[:, 1] - cyb) / fyb], 1)
            thr_a = MAX_ERROR_PIXELS / (0.5 * (fxa + fya))
            thr_b = MAX_ERROR_PIXELS / (0.5 * (fxb + fyb))
            nerr = 0.5 * (thr_a + thr_b)
            Em = mat(E)
            d = os.path.join(out_root, f"real_E_{i1}_{i2}")
            write_fixture(d, a, b, na, nb, Em, Em.T, 1, nerr * nerr,
                          {"source": "db", "db": os.path.basename(db_path), "pair": [i1, i2],
                           "config": config, "coords": "normalized"})
            stats["mode1_E"] += 1
        elif config == 3 and F is not None and len(F) == 72:
            Fm = mat(F)
            d = os.path.join(out_root, f"real_F_{i1}_{i2}")
            write_fixture(d, a, b, xa, xb, Fm, Fm.T, 1, MAX_ERROR_PIXELS ** 2,
                          {"source": "db", "db": os.path.basename(db_path), "pair": [i1, i2],
                           "config": config, "coords": "pixels"})
            stats["mode1_F"] += 1
        elif config in (4, 5, 6) and H is not None and len(H) == 72:
            Hm = mat(H)
            if not np.all(np.isfinite(Hm)) or abs(np.linalg.det(Hm)) < 1e-12:
                stats["skipped"] += 1
                continue
            Hi = np.linalg.inv(Hm)
            d = os.path.join(out_root, f"real_H_{i1}_{i2}")
            write_fixture(d, a, b, xa, xb, Hm, Hi, 2, MAX_ERROR_PIXELS ** 2,
                          {"source": "db", "db": os.path.basename(db_path), "pair": [i1, i2],
                           "config": config, "coords": "pixels"})
            stats["mode2_H"] += 1
        else:
            stats["skipped"] += 1
            continue
        n_written += 1
        if limit and n_written >= limit:
            break
    print("real fixtures:", n_written, stats)


def sift_like(rng, n):
    # non-negative, L2 norm 512, u8-quantised (like SIFT descriptors)
    v = rng.random((n, 128)).astype(np.float64) ** 2
    v /= np.linalg.norm(v, axis=1, keepdims=True)
    return np.clip(np.round(v * 512.0), 0, 255).astype(np.uint8)


def probe_fixtures(out_root, seed=0x9E3779B97F4A7C15 & 0xFFFFFFFF):
    """Synthetic boundary probes for mode 1 (F, pixels) and mode 2 (H, pixels)."""
    rng = np.random.default_rng(seed)
    n = 1024
    res = MAX_ERROR_PIXELS ** 2
    # A random fundamental matrix from two random projective cameras.
    def rand_F():
        K = np.array([[1500.0, 0, 640.0], [0, 1500.0, 480.0], [0, 0, 1]])
        R = np.linalg.qr(rng.standard_normal((3, 3)))[0]
        if np.linalg.det(R) < 0: R[:, 0] *= -1
        t = rng.standard_normal(3); t /= np.linalg.norm(t)
        tx = np.array([[0, -t[2], t[1]], [t[2], 0, -t[0]], [-t[1], t[0], 0]])
        Ki = np.linalg.inv(K)
        F = Ki.T @ tx @ R @ Ki
        return F / np.abs(F).max()
    for eps_i, eps in enumerate([0.0, 1e-6, 1e-4, 1e-2]):
        F = rand_F()
        xa = rng.uniform([0, 0], [1280, 960], (n, 2))
        # Place b_i on the epipolar line of a_i, then offset along the line
        # normal so that the symmetric residual nom²/denom == res·(1+eps).
        xb = np.zeros((n, 2))
        for i in range(n):
            p1 = np.array([xa[i, 0], xa[i, 1], 1.0])
            l2 = F @ p1                                   # line in image 2
            # a point on the line near the image centre
            nrm = l2[:2] / np.linalg.norm(l2[:2])
            x0 = np.array([640.0, 480.0])
            x0 = x0 - (l2[0] * x0[0] + l2[1] * x0[1] + l2[2]) / np.dot(l2[:2], l2[:2]) * l2[:2]
            # solve for offset s along nrm: residual(s) = nom(s)²/denom(s); nom is linear in s
            sign = 1.0 if (i % 2 == 0) else -1.0
            lo, hi = 0.0, 50.0
            def resid(s):
                p2 = np.array([x0[0] + sign * s * nrm[0], x0[1] + sign * s * nrm[1], 1.0])
                l1 = F.T @ p2
                nom = p2 @ l2
                den = l2[0] ** 2 + l2[1] ** 2 + l1[0] ** 2 + l1[1] ** 2
                return nom * nom / den
            target = res * (1.0 + eps) if (i % 4 < 2) else res * (1.0 - eps)
            for _ in range(200):
                mid = 0.5 * (lo + hi)
                if resid(mid) < target: lo = mid
                else: hi = mid
            s = 0.5 * (lo + hi)
            xb[i] = x0 + sign * s * nrm
        # descriptors: b_i is the nearest neighbour of a_i by construction
        # (copy + small noise), the rest random → real top-2 competition
        a = sift_like(rng, n)
        b = a.copy().astype(np.int32) + rng.integers(-6, 7, (n, 128))
        b = np.clip(b, 0, 255).astype(np.uint8)
        perm = rng.permutation(n)
        b_perm = b[perm]              # b row perm[k] ← a row k ... keep xy aligned
        xb_perm = xb[perm]
        d = os.path.join(out_root, f"probe_F_eps{eps_i}")
        write_fixture(d, a, b_perm, xa, xb_perm, F, F.T, 1, res,
                      {"source": "probe", "eps": eps, "note": "b_i placed so that nom^2/denom = res*(1±eps); half above, half below"})
    # mode 2: H = random homography; place b at |Hq/hz - d|² = res(1±eps)
    for eps_i, eps in enumerate([0.0, 1e-6, 1e-4, 1e-2]):
        H = np.eye(3) + 0.05 * rng.standard_normal((3, 3)); H[2, :2] *= 1e-3
        xa = rng.uniform([0, 0], [1280, 960], (n, 2))
        xb = np.zeros((n, 2))
        for i in range(n):
            q = H @ np.array([xa[i, 0], xa[i, 1], 1.0])
            q = q[:2] / q[2]
            ang = rng.uniform(0, 2 * np.pi)
            target = res * (1.0 + eps) if (i % 2 == 0) else res * (1.0 - eps)
            r = np.sqrt(target)
            xb[i] = q + r * np.array([np.cos(ang), np.sin(ang)])
        a = sift_like(rng, n)
        b = np.clip(a.astype(np.int32) + rng.integers(-6, 7, (n, 128)), 0, 255).astype(np.uint8)
        perm = rng.permutation(n)
        d = os.path.join(out_root, f"probe_H_eps{eps_i}")
        write_fixture(d, a, b[perm], xa, xb[perm], H, np.linalg.inv(H), 2, res,
                      {"source": "probe", "eps": eps, "note": "b_i placed at |Hq/hz-d|^2 = res*(1±eps)"})
    print("probe fixtures: 8")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(64)
    cmd = sys.argv[1]
    if cmd == "real":
        real_fixtures(sys.argv[2], sys.argv[3], sys.argv[4],
                      int(sys.argv[5]) if len(sys.argv) > 5 else None)
    elif cmd == "probe":
        probe_fixtures(sys.argv[2])
    else:
        sys.exit(64)
