from __future__ import annotations

import json
from pathlib import Path


RESULT = (
    Path(__file__).resolve().parents[1]
    / "results/worldpack-semantic-complete.json"
)


def test_complete_semantic_worldpack_replaces_only_the_database_local_winner() -> None:
    result = json.loads(RESULT.read_text())
    assert result["schema"] == "pw_worldpack_semantic_complete_result_v1"
    assert result["source_bytes"] == 580_406_089
    assert result["member_count"] == 322
    assert result["previous_complete_persisted_bytes"] == 471_311_917
    assert result["complete_persisted_bytes"] < result[
        "previous_complete_persisted_bytes"
    ]
    assert result["improvement_bytes"] == (
        result["previous_complete_persisted_bytes"]
        - result["complete_persisted_bytes"]
    )
    assert result["database_codec"] == (
        "similarity_forest_webgraph_outer_zpaq_v1"
    )
    assert result["database_archive_bytes"] < 116_739_319
    assert result["unrelated_payloads_reused"] == 321
    assert result["all_members_byte_equal"] == 1
    assert result["all_members_sha256_equal"] == 1
    assert result["sqlite_integrity_check"] == "ok"
    assert result["random_read_count"] == 8
    assert result["random_reads_exact"] == 1
    assert result["corruption_rejected"] == 1
    assert result["source_unchanged"] == 1
    assert result["phone_accessed"] is False
    assert result["production_promoted"] is False
