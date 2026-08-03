import json
from pathlib import Path

import run_phase1


def test_run_writes_phase1_result_atomically(
    tmp_path: Path,
    monkeypatch,
) -> None:
    manifest = tmp_path / "manifest.yaml"
    manifest.write_text("inputs: []\n")
    adapter = tmp_path / "adapter"
    adapter.write_bytes(b"adapter")
    work_directory = tmp_path / "work"
    output = tmp_path / "phase1.json"
    expected = {
        "schema": "pw_plr_brunsli_phase1_v1",
        "status": "phase_1_exact_container_passed",
    }

    monkeypatch.setattr(run_phase1, "execute_phase1", lambda **_: expected)

    run_phase1.run(
        manifest_path=manifest,
        revision="v0.1",
        adapter_path=adapter,
        work_directory=work_directory,
        output_path=output,
    )

    assert json.loads(output.read_text()) == expected
    assert not output.with_suffix(".json.tmp").exists()
