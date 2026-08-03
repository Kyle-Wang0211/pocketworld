from pathlib import Path

import pytest
import yaml

from run_train_phase2 import _verify_runtime_identity


ROOT = Path(__file__).resolve().parents[1]


def test_registered_training_runtime_identity_matches_frozen_files() -> None:
    config_path = ROOT / "phase2-model-config.yaml"
    config = yaml.safe_load(config_path.read_text())

    _verify_runtime_identity(
        config,
        config_path=config_path,
        upstream=ROOT / "build/plr-upstream",
        extractor=ROOT / "build/v0.1/pw_brunsli_training_extract",
    )


def test_registered_training_runtime_rejects_wrong_extractor(
    tmp_path: Path,
) -> None:
    config_path = ROOT / "phase2-model-config.yaml"
    config = yaml.safe_load(config_path.read_text())
    wrong_extractor = tmp_path / "extractor"
    wrong_extractor.write_bytes(b"not the registered extractor")

    with pytest.raises(ValueError, match="extractor identity mismatch"):
        _verify_runtime_identity(
            config,
            config_path=config_path,
            upstream=ROOT / "build/plr-upstream",
            extractor=wrong_extractor,
        )
