import hashlib
from pathlib import Path
import subprocess

from pw_plr.coefficient_archive import (
    build_pwcf_from_mlcc_tiles,
    extract_all_mlcc_tiles,
)
from pw_plr.dct_training import read_training_coefficients


def test_tiled_mlcc_layout_rebuilds_the_original_jpeg_byte_for_byte(
    tmp_path: Path,
) -> None:
    experiment = Path(__file__).resolve().parent.parent
    source = experiment / "data/frozen_pair/cell_85_slot_4.jpg"
    coefficients = read_training_coefficients(
        experiment / "results/work/training-coefficients/A.pwtj"
    )
    tiles = extract_all_mlcc_tiles(coefficients)
    coefficient_path = tmp_path / "A.pwcf"
    coefficient_path.write_bytes(build_pwcf_from_mlcc_tiles(coefficients, tiles))
    restored = tmp_path / "A.restored.jpg"

    subprocess.run(
        [
            str(experiment / "build/v0.1/pw_brunsli_side_adapter"),
            "restore",
            str(experiment / "results/work/v0.1/A/A.pwbs"),
            str(coefficient_path),
            str(restored),
        ],
        check=True,
        capture_output=True,
    )

    assert len(tiles) == 170
    assert tiles[-1].valid_luma_height == 10
    assert tiles[-1].valid_luma_width == 16
    assert restored.read_bytes() == source.read_bytes()
    assert hashlib.sha256(restored.read_bytes()).hexdigest() == (
        "ac91faba107c41f891dbce7128f0ecc8e66cb451892e231479d8bf8b738e4be6"
    )
