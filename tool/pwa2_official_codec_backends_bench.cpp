// The implementation is shared with the two-phase screening harness so the
// exact same parsing, reversible transforms, codec adapters, and accounting
// are used by both the sample and full-compatible-stream runs.
//
// Evidence fields emitted by the full run include:
// complete_persisted_bytes (as projected_complete_persisted_bytes),
// logical_sha256_equal, all_cells_equal, all_rows_and_order_equal,
// random_reads_exact, materialized_sqlite_integrity_ok, source_unchanged,
// and selected_codec. A successful run ends with
// PW_PWA2_OFFICIAL_CODECS_BENCH_OK.
#include "pwa2_official_codec_sample_bench.cpp"
