from pathlib import Path
import subprocess

from pw_plr.input_identity import verify_inputs


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "build" / "v0.1" / "pw_brunsli_side_adapter"


def _run(*arguments: Path | str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(ADAPTER), *(str(argument) for argument in arguments)],
        check=False,
        capture_output=True,
        text=True,
    )


def _flip_middle_byte(source: Path, destination: Path) -> None:
    payload = bytearray(source.read_bytes())
    payload[len(payload) // 2] ^= 0x01
    destination.write_bytes(payload)


def test_adapter_round_trips_frozen_input_a_and_rejects_corruption(
    tmp_path: Path,
) -> None:
    source = verify_inputs(ROOT / "input-manifest.yaml")[0].path
    side = tmp_path / "a.side"
    coefficients = tmp_path / "a.coeff"
    restored = tmp_path / "a.restored.jpg"

    extracted = _run("extract", source, side, coefficients)
    assert extracted.returncode == 0, extracted.stderr
    assert side.stat().st_size > 64
    assert coefficients.stat().st_size > 64

    decoded = _run("restore", side, coefficients, restored)
    assert decoded.returncode == 0, decoded.stderr
    assert restored.read_bytes() == source.read_bytes()

    for label, corrupt_side, corrupt_coefficients in (
        ("side-bitflip", True, False),
        ("coeff-bitflip", False, True),
    ):
        candidate_side = tmp_path / f"{label}.side"
        candidate_coefficients = tmp_path / f"{label}.coeff"
        if corrupt_side:
            _flip_middle_byte(side, candidate_side)
            candidate_coefficients.write_bytes(coefficients.read_bytes())
        else:
            candidate_side.write_bytes(side.read_bytes())
            _flip_middle_byte(coefficients, candidate_coefficients)
        output = tmp_path / f"{label}.jpg"

        rejected = _run(
            "restore", candidate_side, candidate_coefficients, output
        )

        assert rejected.returncode != 0
        assert not output.exists()

    truncated_side = tmp_path / "truncated.side"
    truncated_side.write_bytes(side.read_bytes()[:-1])
    truncated_output = tmp_path / "truncated.jpg"

    rejected = _run("restore", truncated_side, coefficients, truncated_output)

    assert rejected.returncode != 0
    assert not truncated_output.exists()
