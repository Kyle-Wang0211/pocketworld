import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_full_project_logical_photo_manifest_is_complete_and_exact() -> None:
    result = json.loads(
        (ROOT / "results/worldpack-logical-photo-manifest.json").read_text()
    )
    assert result["schema"] == "pw_worldpack_logical_photo_manifest_v1"
    assert result["logical_photo_count"] == 155
    assert result["jxl_backed_photo_count"] == 111
    assert result["jpeg_backed_photo_count"] == 44
    assert result["logical_original_jpeg_bytes"] == 436_234_141
    assert result["current_stored_photo_bytes"] == 377_994_598
    assert result["source_unchanged"] == 1
    assert len({item["logical_path"] for item in result["photos"]}) == 155
    for item in result["photos"]:
        logical = Path(item["logical_jpeg_path"])
        assert logical.stat().st_size == item["logical_bytes"]
        assert hashlib.sha256(logical.read_bytes()).hexdigest() == item["logical_sha256"]

