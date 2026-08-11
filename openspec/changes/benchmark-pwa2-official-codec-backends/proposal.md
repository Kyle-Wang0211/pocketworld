# Change: Benchmark official PWA2 codec backends

## Why

PWA2 plus uniform ZPAQ was exact but larger than the current production
baseline. Official type- and format-aware codecs have not yet been measured on
the same logical structure, so their local and complete-archive value remains
unknown.

## What Changes

- Add a host-only benchmark for pinned OpenZL, Pcodec, and C-Blosc2 releases.
- Keep identical input and PWA2 logical semantics while selecting only exact
  codec candidates per compatible stream.
- Verify complete restoration and count every persisted byte.
- Promote any strictly smaller exact candidate as the new baseline for its
  comparable algorithm scope, even when the improvement is below 10%.
- Make no production or phone changes.

## Post-run decision

Pcodec level 12 won all 66 compatible numeric members. The PWA2 accounting
baseline is therefore promoted from `129,567,942` bytes (all ZPAQ) to
`129,201,499` bytes (Pcodec numeric members plus ZPAQ fallback). This is the
new PWA2 research baseline; it does not replace the separate `124,401,918`
byte production `track_delta + ZPAQ` baseline.
