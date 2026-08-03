"""Phase 1 exact-container execution and evidence collection."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess

from pw_plr.input_identity import verify_inputs


BRUNSLI_COMMITS = {
    "v0.1": "8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c",
    "master": "c9128f43994c1ca830dd079777d85f16736d6ba7",
}
ENVELOPE_HEADER_BYTES = 88


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _run_adapter(
    adapter_path: Path,
    *arguments: Path | str,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(adapter_path), *(str(argument) for argument in arguments)],
        check=False,
        capture_output=True,
        text=True,
    )


def _require_success(completed: subprocess.CompletedProcess[str]) -> None:
    if completed.returncode != 0:
        raise RuntimeError(
            "Brunsli adapter failed: "
            f"returncode={completed.returncode} stderr={completed.stderr.strip()}"
        )


def _side_section_tags(side_file: bytes) -> list[int]:
    payload = side_file[ENVELOPE_HEADER_BYTES:]
    tags: list[int] = []
    position = 0
    while position < len(payload):
        marker = payload[position]
        position += 1
        tags.append(marker >> 3)
        section_bytes = 0
        shift = 0
        while True:
            if position >= len(payload) or shift > 56:
                raise ValueError("invalid Brunsli section length")
            encoded = payload[position]
            position += 1
            section_bytes |= (encoded & 0x7F) << shift
            if encoded & 0x80 == 0:
                break
            shift += 7
        if section_bytes > len(payload) - position:
            raise ValueError("Brunsli section exceeds side payload")
        position += section_bytes
    return tags


def _flip_payload_byte(envelope: bytes) -> bytes:
    changed = bytearray(envelope)
    changed[ENVELOPE_HEADER_BYTES + (len(changed) - ENVELOPE_HEADER_BYTES) // 2] ^= 1
    return bytes(changed)


def _coefficient_count_mismatch(envelope: bytes) -> bytes:
    changed = bytearray(envelope)
    payload = changed[ENVELOPE_HEADER_BYTES:]
    component_count = int.from_bytes(payload[:4], "little")
    payload[:4] = (component_count + 1).to_bytes(4, "little")
    changed[ENVELOPE_HEADER_BYTES:] = payload
    changed[24:56] = hashlib.sha256(payload).digest()
    return bytes(changed)


def _corruption_variants(
    side_file: bytes,
    coefficient_file: bytes,
) -> dict[str, tuple[bytes, bytes]]:
    wrong_version = bytearray(side_file)
    wrong_version[4] = ord("2")
    return {
        "side_bitflip": (_flip_payload_byte(side_file), coefficient_file),
        "coefficient_bitflip": (
            side_file,
            _flip_payload_byte(coefficient_file),
        ),
        "side_truncated": (side_file[:-1], coefficient_file),
        "coefficient_truncated": (side_file, coefficient_file[:-1]),
        "side_appended": (side_file + b"\x00", coefficient_file),
        "wrong_side_version": (bytes(wrong_version), coefficient_file),
        "coefficient_count_mismatch": (
            side_file,
            _coefficient_count_mismatch(coefficient_file),
        ),
    }


def _run_corruption_probes(
    *,
    adapter_path: Path,
    role_directory: Path,
    side_file: bytes,
    coefficient_file: bytes,
) -> dict[str, bool]:
    outcomes: dict[str, bool] = {}
    for name, (candidate_side, candidate_coefficients) in _corruption_variants(
        side_file, coefficient_file
    ).items():
        side_path = role_directory / f"corrupt-{name}.pwbs"
        coefficient_path = role_directory / f"corrupt-{name}.pwcf"
        output_path = role_directory / f"corrupt-{name}.jpg"
        side_path.write_bytes(candidate_side)
        coefficient_path.write_bytes(candidate_coefficients)
        completed = _run_adapter(
            adapter_path,
            "restore",
            side_path,
            coefficient_path,
            output_path,
        )
        outcomes[name] = completed.returncode != 0 and not output_path.exists()
    return outcomes


def run_phase1(
    *,
    manifest_path: Path,
    adapter_path: Path,
    revision: str,
    work_directory: Path,
) -> dict[str, object]:
    if revision not in BRUNSLI_COMMITS:
        raise ValueError("revision must be v0.1 or master")
    if not adapter_path.is_file():
        raise FileNotFoundError(adapter_path)

    verified_inputs = verify_inputs(manifest_path)
    adapter_sha256 = _sha256_file(adapter_path)
    input_results: list[dict[str, object]] = []
    for item in verified_inputs:
        role_directory = work_directory / item.role
        role_directory.mkdir(parents=True, exist_ok=True)
        side_path = role_directory / f"{item.role}.pwbs"
        coefficient_path = role_directory / f"{item.role}.pwcf"
        restored_path = role_directory / f"{item.role}.restored.jpg"

        source_sha256_before = _sha256_file(item.path)
        _require_success(
            _run_adapter(
                adapter_path,
                "extract",
                item.path,
                side_path,
                coefficient_path,
            )
        )
        _require_success(
            _run_adapter(
                adapter_path,
                "restore",
                side_path,
                coefficient_path,
                restored_path,
            )
        )

        source_bytes = item.path.read_bytes()
        restored_bytes = restored_path.read_bytes()
        side_bytes = side_path.read_bytes()
        coefficient_bytes = coefficient_path.read_bytes()
        source_sha256_after = _sha256_file(item.path)
        restored_sha256 = _sha256_bytes(restored_bytes)
        byte_equal = restored_bytes == source_bytes
        sha256_equal = restored_sha256 == item.sha256
        source_unchanged = source_sha256_after == source_sha256_before == item.sha256
        corruption_rejected = _run_corruption_probes(
            adapter_path=adapter_path,
            role_directory=role_directory,
            side_file=side_bytes,
            coefficient_file=coefficient_bytes,
        )
        section_tags = _side_section_tags(side_bytes)
        if not byte_equal or not sha256_equal or not source_unchanged:
            raise RuntimeError(f"exactness failure for role {item.role}")
        if section_tags != [1, 2, 4, 3, 5]:
            raise RuntimeError(
                f"unexpected side sections for role {item.role}: {section_tags}"
            )
        if not all(corruption_rejected.values()):
            raise RuntimeError(f"corruption gate failure for role {item.role}")

        input_results.append(
            {
                "role": item.role,
                "source_path": str(item.path),
                "source_bytes": item.bytes,
                "source_sha256": item.sha256,
                "side_bytes": len(side_bytes),
                "side_sha256": _sha256_bytes(side_bytes),
                "side_section_tags": section_tags,
                "coefficient_bytes": len(coefficient_bytes),
                "coefficient_sha256": _sha256_bytes(coefficient_bytes),
                "restored_bytes": len(restored_bytes),
                "restored_sha256": restored_sha256,
                "byte_equal": byte_equal,
                "sha256_equal": sha256_equal,
                "source_unchanged": source_unchanged,
                "corruption_rejected": corruption_rejected,
            }
        )

    return {
        "schema": "pw_plr_brunsli_phase1_v1",
        "status": "phase_1_exact_container_passed",
        "revision": revision,
        "brunsli_commit": BRUNSLI_COMMITS[revision],
        "adapter_path": str(adapter_path),
        "adapter_sha256": adapter_sha256,
        "inputs": input_results,
        "complete_pair_phase1_bytes": sum(
            int(item["side_bytes"]) + int(item["coefficient_bytes"])
            for item in input_results
        ),
        "terminal_compression_verdict": "not_authorized_before_phase_4",
    }
