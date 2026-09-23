#!/usr/bin/env python3
"""Regenerate fixtures/pwvi_to_euroc_rescale_<rec>_d<d>.csv.

The fixture pins PWXrslamTransportScaleIntrinsicsForBoxNxN to the output of
the offline converter that produced the per-frame-K replay evidence
(arloopbench tools/pwvi_to_euroc.py, `--downscale d --intrinsics-csv`).
Nothing here re-implements the rescale: the expected columns are copied
verbatim from the converter's CSV. This script only recovers, for each CSV
row, the raw intrinsics.jsonl row the converter paired it with, using the
converter's own rule (pwvi_to_euroc.py:135-162: nearest `t` within 1 ms of
camera_index timestamp_ns). Without --exposure-half the converter writes
t_out == camera_index timestamp_ns (pwvi_to_euroc.py:218-219).

Usage (needs numpy + Pillow because the converter imports them):
  python3.11 make_rescale_fixture.py <pwvi_to_euroc.py> <run-* dir> <scratch dir> \
      [--downscale 3] [--limit 120] > fixtures/pwvi_to_euroc_rescale_<rec>_d3.csv
"""
import argparse
import bisect
import csv
import hashlib
import json
import os
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('converter')
    ap.add_argument('recording')
    ap.add_argument('scratch')
    ap.add_argument('--downscale', type=int, default=3)
    ap.add_argument('--limit', type=int, default=120)
    a = ap.parse_args()

    out_dir = os.path.join(a.scratch, 'euroc_fixture_out')
    k_csv = os.path.join(a.scratch, 'converter_intrinsics.csv')
    cmd = [sys.executable, a.converter, a.recording, out_dir,
           '--downscale', str(a.downscale), '--intrinsics-csv', k_csv,
           '--limit', str(a.limit)]
    subprocess.run(cmd, check=True, stdout=sys.stderr, stderr=sys.stderr)

    recs = [json.loads(l) for l in open(os.path.join(a.recording, 'intrinsics.jsonl'))
            if l.strip()]
    table = sorted(((int(round(float(r['t']) * 1e9)), r) for r in recs if 't' in r),
                   key=lambda x: x[0])
    keys = [t for t, _ in table]

    def raw_for(t_ns):
        i = bisect.bisect_left(keys, t_ns)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(keys) and abs(keys[j] - t_ns) <= 1_000_000:
                if best is None or abs(keys[j] - t_ns) < abs(keys[best] - t_ns):
                    best = j
        if best is None:
            raise SystemExit(f'no intrinsics.jsonl row within 1 ms of {t_ns}')
        return table[best][1]['intrinsics_fxfycxcy']

    conv_sha = hashlib.sha256(open(a.converter, 'rb').read()).hexdigest()
    print(f'# source recording: {os.path.basename(os.path.normpath(a.recording))}')
    print(f'# converter: {os.path.basename(a.converter)} sha256 {conv_sha}')
    print(f'# converter command: pwvi_to_euroc.py <recording> <out> --downscale {a.downscale} '
          f'--intrinsics-csv <csv> --limit {a.limit}')
    print(f'# python: {sys.version.split()[0]}')
    print('# t_ns,raw_fx,raw_fy,raw_cx,raw_cy,factor,conv_fx,conv_fy,conv_cx,conv_cy')
    n = 0
    with open(k_csv) as f:
        for row in csv.reader(f):
            if not row or row[0].startswith('#'):
                continue
            t_ns = int(row[0])
            raw = raw_for(t_ns)
            print(','.join([str(t_ns)] + [repr(float(v)) for v in raw] +
                           [str(a.downscale)] + row[1:5]))
            n += 1
    print(f'fixture rows: {n}', file=sys.stderr)


if __name__ == '__main__':
    main()
