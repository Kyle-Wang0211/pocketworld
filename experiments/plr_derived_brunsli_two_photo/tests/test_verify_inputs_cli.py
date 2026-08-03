import hashlib
import json
from pathlib import Path

import yaml

from run_verify_inputs import run


def test_run_writes_verified_inputs_atomically(tmp_path: Path) -> None:
    source = tmp_path / "source.jpg"
    source.write_bytes(b"registered-source")
    manifest = tmp_path / "manifest.yaml"
    manifest.write_text(
        yaml.safe_dump(
            {
                "inputs": [
                    {
                        "role": "A",
                        "filename": source.name,
                        "path": str(source),
                        "bytes": source.stat().st_size,
                        "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                    }
                ]
            },
            sort_keys=False,
        )
    )
    output = tmp_path / "result.json"

    run(manifest, output)

    result = json.loads(output.read_text())
    assert result["schema"] == "pw_plr_input_verification_v1"
    assert result["status"] == "verified"
    assert result["inputs"] == [
        {
            "role": "A",
            "path": str(source),
            "bytes": 17,
            "sha256": hashlib.sha256(b"registered-source").hexdigest(),
        }
    ]
    assert not output.with_suffix(".json.tmp").exists()
