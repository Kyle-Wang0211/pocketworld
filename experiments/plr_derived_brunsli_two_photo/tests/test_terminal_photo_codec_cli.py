from array import array
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys

import torch
import yaml

from pw_plr.coefficient_archive import (
    build_pwcf_from_mlcc_tiles,
    extract_all_mlcc_tiles,
)
from pw_plr.dct_training import DctComponent, TrainingCoefficients


ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = Path(os.environ.get("PW_PLR_SOURCE_ROOT", ROOT / "build/plr-upstream"))
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


def _coefficients() -> TrainingCoefficients:
    generator = torch.Generator().manual_seed(20260804)

    def component(
        component_id: int,
        h_samp: int,
        v_samp: int,
        width: int,
        height: int,
    ) -> DctComponent:
        values = torch.randint(
            -8,
            9,
            (height * width * 64,),
            generator=generator,
            dtype=torch.int16,
        )
        return DctComponent(
            component_id=component_id,
            h_samp_factor=h_samp,
            v_samp_factor=v_samp,
            quant_idx=component_id - 1,
            width_in_blocks=width,
            height_in_blocks=height,
            coefficients=array("h", values.tolist()),
        )

    return TrainingCoefficients(
        width=256,
        height=256,
        max_h_samp_factor=2,
        max_v_samp_factor=2,
        source_bytes=123_456,
        source_sha256=hashlib.sha256(b"separate-process-source").hexdigest(),
        components=(
            component(1, 2, 2, 32, 32),
            component(2, 1, 1, 16, 16),
            component(3, 1, 1, 16, 16),
        ),
    )


def _write_pwtj(path: Path, coefficients: TrainingCoefficients) -> None:
    payload = bytearray(
        struct.pack(
            "<5I",
            coefficients.width,
            coefficients.height,
            coefficients.max_h_samp_factor,
            coefficients.max_v_samp_factor,
            len(coefficients.components),
        )
    )
    for component in coefficients.components:
        values = array("h", component.coefficients)
        if sys.byteorder != "little":
            values.byteswap()
        payload.extend(
            struct.pack(
                "<6IQ",
                component.component_id,
                component.h_samp_factor,
                component.v_samp_factor,
                component.quant_idx,
                component.width_in_blocks,
                component.height_in_blocks,
                len(values),
            )
        )
        payload.extend(values.tobytes())
    document = (
        b"PWTJ1\0\0\0"
        + struct.pack("<Q", len(payload))
        + hashlib.sha256(payload).digest()
        + struct.pack("<Q", coefficients.source_bytes)
        + bytes.fromhex(coefficients.source_sha256)
        + payload
    )
    path.write_bytes(document)


def _run(*arguments: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "OMP_NUM_THREADS": "1",
            "MKL_NUM_THREADS": "1",
            "VECLIB_MAXIMUM_THREADS": "1",
        }
    )
    return subprocess.run(
        [sys.executable, str(ROOT / "run_terminal_photo_codec.py"), *arguments],
        cwd=ROOT,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )


def test_terminal_codec_uses_separate_processes_and_preserves_every_coefficient(
    tmp_path: Path,
) -> None:
    torch.manual_seed(20260804)
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    checkpoint = tmp_path / "best.pt"
    torch.save(
        {
            "schema": "pw_plr_phase2_checkpoint_v1",
            "arm": "tiny",
            "model": model.state_dict(),
        },
        checkpoint,
    )
    config = tmp_path / "config.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "model_arms": [{"id": "tiny", "N": 8, "M": 12}],
                "implementation": {"chunks": ["scales", "means"]},
            }
        )
    )
    coefficients = _coefficients()
    coefficient_path = tmp_path / "source.pwtj"
    _write_pwtj(coefficient_path, coefficients)
    archive = tmp_path / "photo.pwpa"
    artifact = tmp_path / "model.pwmod"
    encoder_trace = tmp_path / "encoder-trace.json"
    decoder_trace = tmp_path / "decoder-trace.json"
    restored_pwcf = tmp_path / "restored.pwcf"

    encoded = _run(
        "encode",
        "--checkpoint",
        str(checkpoint),
        "--config",
        str(config),
        "--upstream",
        str(UPSTREAM),
        "--coefficients",
        str(coefficient_path),
        "--archive",
        str(archive),
        "--model-artifact",
        str(artifact),
        "--trace",
        str(encoder_trace),
    )
    assert encoded.returncode == 0, encoded.stderr
    artifact_archive = tmp_path / "photo-from-artifact.pwpa"
    artifact_trace = tmp_path / "artifact-encoder-trace.json"
    encoded_from_artifact = _run(
        "encode-artifact",
        "--upstream",
        str(UPSTREAM),
        "--model-artifact",
        str(artifact),
        "--coefficients",
        str(coefficient_path),
        "--archive",
        str(artifact_archive),
        "--trace",
        str(artifact_trace),
    )
    assert encoded_from_artifact.returncode == 0, encoded_from_artifact.stderr
    assert artifact_archive.read_bytes() == archive.read_bytes()
    assert artifact_trace.read_bytes() == encoder_trace.read_bytes()
    decoded = _run(
        "decode",
        "--upstream",
        str(UPSTREAM),
        "--model-artifact",
        str(artifact),
        "--archive",
        str(archive),
        "--pwcf",
        str(restored_pwcf),
        "--trace",
        str(decoder_trace),
    )
    assert decoded.returncode == 0, decoded.stderr

    expected_pwcf = build_pwcf_from_mlcc_tiles(
        coefficients,
        extract_all_mlcc_tiles(coefficients),
    )
    assert restored_pwcf.read_bytes() == expected_pwcf
    assert encoder_trace.read_bytes() == decoder_trace.read_bytes()
