# PW Match thermal diagnostic — non-qualifying load

- Device: iPhone15,2, iOS 26.5
- Started: 2026-07-15 17:14:26 +08:00
- Duration: 300.01686575 s
- Matcher runs: 3621; exact-set passes: 3621; failures: 0
- Warm median: 81.636958 ms
- Final RSS: 178.203125 MiB
- Observed thermal: nominal throughout
- Result: `thermal_incomplete`

This isolates the Metal matcher and does not reproduce the camera, JPEG/gray
encoding, durable writes, AR session, rendering, and live-SfM concurrency of a
real PocketWorld capture. The user reports that the actual capture path reaches
`serious` at roughly three minutes. Therefore this run is retained as matcher
correctness/stability evidence only and must not be used to accept E thermal P0.

Artifact SHA-256:

- `latest.json`: `f1b606bb4f49b6a44a07a43ba7db1fae7b0469f8a0e3fe9dac7522736fc0ab0e`
- `cold_output_pairs.u32`: `2e3ba175061fc7c4d46bb39c838eef7b186df55ec908c1448d3c1ba0a886cc52`
