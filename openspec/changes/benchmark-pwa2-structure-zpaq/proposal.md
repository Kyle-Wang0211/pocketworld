# Change: Benchmark PWA2 structure with the frozen ZPAQ backend

## Why

`track_delta_v1 + ZPAQ` is the current exact SQLite archive baseline at
124,401,918 bytes, but only 17.9% of descriptor vectors are predicted and the
result still mixes roots, residuals, literals, numeric columns, and SQLite page
metadata. A logical future-project format can expose the same verified SfM
relationships without changing the entropy backend.

## What Changes

- Add an independent benchmark-only PWA2 logical packer and reader.
- Split descriptor roots, track residuals, and unmatched literals into
  byte-lane-major bounded blocks.
- Store keypoints and match arrays as exact typed columns.
- Preserve every table and query-visible value, but not SQLite page history.
- Compress every persisted member with the pinned ZPAQ 7.15 method 5 bridge.
- Reject on the host unless complete persisted bytes are at most 111,961,726.

## Impact

Only new OpenSpec, experiment, native test, and host benchmark files are in
scope. Production archive policy and the production iPhone bundle are not
modified or installed.
