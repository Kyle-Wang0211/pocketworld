# Design: Official codec competition on PWA2 streams

PWA2 remains the logical front end. ZPAQ remains the fallback for every member.
Official codecs may compete only on data types and layouts they explicitly
support, and a candidate is eligible only after immediate byte-exact decode.
The selected-codec manifest is itself checksummed and included in the complete
container size. A final full decode reuses the PWA2 logical verifier and SQLite
materializer.

## Baseline hierarchy

- Production/global baseline: `track_delta + ZPAQ`, `124,401,918` bytes.
- PWA2 previous baseline: all members using ZPAQ, `129,567,942` bytes.
- PWA2 current baseline: Pcodec level 12 for the 66 numeric members and ZPAQ
  for every other member, `129,201,499` comparable accounted bytes.

The current PWA2 value is an accepted research baseline because every replaced
member decoded byte-identically and the complete accounting is smaller by
`366,443` bytes. It remains separate from production promotion: an actual full
container and phone validation are still required before changing production.
