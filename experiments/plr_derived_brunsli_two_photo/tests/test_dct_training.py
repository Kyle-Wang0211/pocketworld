import hashlib
import json
import struct
import subprocess
from pathlib import Path

import pytest

from pw_plr.dct_training import (
    deterministic_patch_origin,
    extract_mlcc_patch,
    extract_plr_patch,
    read_training_coefficients,
    read_training_coefficients_bytes,
)


MAGIC = b"PWTJ1\0\0\0"


def _fixture(*, corrupt_payload: bool = False) -> bytes:
    coefficients = (1, -2, 3, -4) + (0,) * 60
    payload = struct.pack("<5I", 8, 8, 1, 1, 1)
    payload += struct.pack("<6IQ", 1, 1, 1, 0, 1, 1, len(coefficients))
    payload += struct.pack(f"<{len(coefficients)}h", *coefficients)
    payload_sha = hashlib.sha256(payload).digest()
    if corrupt_payload:
        payload = payload[:-1] + bytes([payload[-1] ^ 1])
    source_sha = hashlib.sha256(b"source-jpeg").digest()
    return (
        MAGIC
        + struct.pack("<Q", len(payload))
        + payload_sha
        + struct.pack("<Q", len(b"source-jpeg"))
        + source_sha
        + payload
    )


def test_read_training_coefficients_preserves_shape_and_int16_bits(
    tmp_path: Path,
) -> None:
    path = tmp_path / "sample.pwtj"
    path.write_bytes(_fixture())

    result = read_training_coefficients(path)

    assert result.width == 8
    assert result.height == 8
    assert result.max_h_samp_factor == 1
    assert result.max_v_samp_factor == 1
    assert result.source_bytes == len(b"source-jpeg")
    assert result.source_sha256 == hashlib.sha256(b"source-jpeg").hexdigest()
    assert len(result.components) == 1
    component = result.components[0]
    assert component.width_in_blocks == 1
    assert component.height_in_blocks == 1
    assert list(component.coefficients[:4]) == [1, -2, 3, -4]
    assert list(component.coefficients[4:]) == [0] * 60


def test_read_training_coefficients_rejects_payload_corruption(
    tmp_path: Path,
) -> None:
    path = tmp_path / "corrupt.pwtj"
    path.write_bytes(_fixture(corrupt_payload=True))

    with pytest.raises(ValueError, match="payload SHA-256 mismatch"):
        read_training_coefficients(path)


def test_read_training_coefficients_rejects_shape_count_mismatch(
    tmp_path: Path,
) -> None:
    data = bytearray(_fixture())
    header_bytes = 8 + 8 + 32 + 8 + 32
    coefficient_count_offset = header_bytes + 5 * 4 + 6 * 4
    data[coefficient_count_offset : coefficient_count_offset + 8] = struct.pack(
        "<Q", 63
    )
    payload = bytes(data[header_bytes:])
    data[16:48] = hashlib.sha256(payload).digest()
    path = tmp_path / "bad-shape.pwtj"
    path.write_bytes(data)

    with pytest.raises(ValueError, match="coefficient count does not match"):
        read_training_coefficients(path)


def _fixture_420() -> bytes:
    payload = struct.pack("<5I", 16, 16, 2, 2, 3)
    components = (
        (1, 2, 2, 0, 2, 2, tuple(range(64)) * 4),
        (2, 1, 1, 1, 1, 1, tuple(range(64))),
        (3, 1, 1, 1, 1, 1, tuple(range(-64, 0))),
    )
    for component_id, h_samp, v_samp, quant_idx, width, height, values in components:
        payload += struct.pack(
            "<6IQ",
            component_id,
            h_samp,
            v_samp,
            quant_idx,
            width,
            height,
            len(values),
        )
        payload += struct.pack(f"<{len(values)}h", *values)
    return (
        MAGIC
        + struct.pack("<Q", len(payload))
        + hashlib.sha256(payload).digest()
        + struct.pack("<Q", len(b"source-jpeg"))
        + hashlib.sha256(b"source-jpeg").digest()
        + payload
    )


def test_extract_plr_patch_preserves_exact_values_and_420_geometry(
    tmp_path: Path,
) -> None:
    path = tmp_path / "sample-420.pwtj"
    path.write_bytes(_fixture_420())

    patch = extract_plr_patch(
        read_training_coefficients(path),
        luma_top=0,
        luma_left=0,
        luma_blocks=2,
    )

    assert tuple(patch["Y"].shape) == (2, 2, 64)
    assert tuple(patch["Cb"].shape) == (1, 1, 64)
    assert tuple(patch["Cr"].shape) == (1, 1, 64)
    assert patch["Y"].dtype.is_floating_point
    assert patch["Y"][0, 0, 0].item() == 63
    assert patch["Y"][0, 0, -1].item() == 0
    assert patch["Cr"].to(dtype=patch["Cr"].int().dtype).equal(patch["Cr"].int())


def test_extract_plr_patch_rejects_non_420_or_odd_origin(tmp_path: Path) -> None:
    path = tmp_path / "sample-420.pwtj"
    path.write_bytes(_fixture_420())
    coefficients = read_training_coefficients(path)

    with pytest.raises(ValueError, match="even luma block origin"):
        extract_plr_patch(
            coefficients,
            luma_top=1,
            luma_left=0,
            luma_blocks=2,
        )


def test_extract_mlcc_patch_uses_y_groups_and_exact_chroma_planes(
    tmp_path: Path,
) -> None:
    path = tmp_path / "sample-420.pwtj"
    path.write_bytes(_fixture_420())

    patch = extract_mlcc_patch(
        read_training_coefficients(path),
        luma_top=0,
        luma_left=0,
        luma_blocks=2,
    )

    assert tuple(patch["Y"].shape) == (2, 2, 64)
    assert tuple(patch["Cb"].shape) == (1, 8, 8)
    assert tuple(patch["Cr"].shape) == (1, 8, 8)
    assert patch["Cb"][0, 0, 0].item() == 0
    assert patch["Cb"][0, 7, 7].item() == 63
    assert patch["Cr"][0, 0, 0].item() == -64
    assert patch["Cr"][0, 7, 7].item() == -1


def test_training_extractor_probe_reports_frozen_photo_geometry() -> None:
    experiment = Path(__file__).resolve().parent.parent
    completed = subprocess.run(
        [
            str(experiment / "build/v0.1/pw_brunsli_training_extract"),
            "--probe",
            str(experiment / "data/frozen_pair/cell_85_slot_4.jpg"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    result = json.loads(completed.stdout)
    assert result["width"] == 4224
    assert result["height"] == 2376
    assert result["component_count"] == 3
    assert result["luma_width_in_blocks"] == 528
    assert result["luma_height_in_blocks"] == 298
    assert result["subsampling"] == "4:2:0"
    assert result["eligible_plr_420"] is True
    assert result["source_sha256"] == (
        "ac91faba107c41f891dbce7128f0ecc8e66cb451892e231479d8bf8b738e4be6"
    )


def test_native_patch_extraction_matches_full_coefficient_crop(tmp_path: Path) -> None:
    experiment = Path(__file__).resolve().parent.parent
    source = experiment / "data/frozen_pair/cell_85_slot_4.jpg"
    full_path = tmp_path / "full.pwtj"
    patch_path = tmp_path / "patch.pwtj"
    binary = experiment / "build/v0.1/pw_brunsli_training_extract"
    subprocess.run([str(binary), str(source), str(full_path)], check=True)
    subprocess.run(
        [
            str(binary),
            "--extract-patch",
            str(source),
            str(patch_path),
            "2",
            "4",
            "32",
        ],
        check=True,
    )

    full = extract_mlcc_patch(
        read_training_coefficients(full_path),
        luma_top=2,
        luma_left=4,
        luma_blocks=32,
    )
    patch = extract_mlcc_patch(
        read_training_coefficients(patch_path),
        luma_top=0,
        luma_left=0,
        luma_blocks=32,
    )

    assert patch["Y"].equal(full["Y"])
    assert patch["Cb"].equal(full["Cb"])
    assert patch["Cr"].equal(full["Cr"])


def test_native_patch_can_stream_the_same_envelope_to_stdout(tmp_path: Path) -> None:
    experiment = Path(__file__).resolve().parent.parent
    source = experiment / "data/frozen_pair/cell_85_slot_4.jpg"
    binary = experiment / "build/v0.1/pw_brunsli_training_extract"
    completed = subprocess.run(
        [
            str(binary),
            "--extract-patch",
            str(source),
            "-",
            "2",
            "4",
            "32",
        ],
        check=True,
        capture_output=True,
    )

    coefficients = read_training_coefficients_bytes(completed.stdout)
    patch = extract_mlcc_patch(
        coefficients,
        luma_top=0,
        luma_left=0,
        luma_blocks=32,
    )

    assert tuple(patch["Y"].shape) == (32, 32, 64)
    assert tuple(patch["Cb"].shape) == (1, 128, 128)
    assert tuple(patch["Cr"].shape) == (1, 128, 128)


def test_deterministic_patch_origin_is_even_bounded_and_epoch_specific() -> None:
    first = deterministic_patch_origin(
        width_in_luma_blocks=264,
        height_in_luma_blocks=150,
        luma_blocks=32,
        image_sha256="a" * 64,
        epoch=0,
        seed=20260803,
    )
    repeated = deterministic_patch_origin(
        width_in_luma_blocks=264,
        height_in_luma_blocks=150,
        luma_blocks=32,
        image_sha256="a" * 64,
        epoch=0,
        seed=20260803,
    )
    later = deterministic_patch_origin(
        width_in_luma_blocks=264,
        height_in_luma_blocks=150,
        luma_blocks=32,
        image_sha256="a" * 64,
        epoch=1,
        seed=20260803,
    )

    assert first == repeated
    assert first != later
    top, left = first
    assert top % 2 == 0 and left % 2 == 0
    assert 0 <= top <= 150 - 32
    assert 0 <= left <= 264 - 32
