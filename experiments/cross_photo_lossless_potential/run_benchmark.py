from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import lzma
import os
from pathlib import Path
import random
import resource
import shutil
import subprocess
import tempfile
import time
from typing import Any, Sequence

import mlflow
import yaml

from cross_photo_estimator import (
    ArchiveFrame,
    adjacent_pairs,
    build_prediction_mappings,
    build_result,
    decode_group_payload,
    encode_group_payload,
    load_binary_ply_xyz,
    load_registered_poses,
    make_groups,
    parse_pwc,
    ratio_threshold_impossible,
    serialize_pwc,
)


MINIMUM_RATIO = 2.165
RANDOM_ACCESS_SEED = 20260730
XZ_PRESET = 9 | lzma.PRESET_EXTREME


@dataclass(frozen=True)
class InputPhoto:
    index: int
    name: str
    path: Path
    bytes: int
    sha256: str


@dataclass
class ArmState:
    name: str
    source_jpeg_bytes: int
    archive_bytes: int = 0
    exactness_failures: int = 0
    input_hash_failures: int = 0
    valid_sparse_projections: int = 0
    random_access_group_overflow: int = 0
    mapped_blocks: int = 0
    total_blocks: int = 0
    encode_elapsed_ms: float = 0.0
    decode_elapsed_ms: float = 0.0
    peak_temp_bytes: int = 0
    deterministic_archive_hash: bool = True
    corruption_rejected: bool = False
    source_unchanged: bool = False


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def files_equal(first: Path, second: Path) -> bool:
    if first.stat().st_size != second.stat().st_size:
        return False
    with first.open("rb") as left, second.open("rb") as right:
        while True:
            left_block = left.read(1024 * 1024)
            right_block = right.read(1024 * 1024)
            if left_block != right_block:
                return False
            if not left_block:
                return True


def directory_bytes(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, sort_keys=True, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    if json.loads(path.read_text(encoding="utf-8")) != value:
        raise RuntimeError(f"persisted result readback mismatch: {path}")


def atomic_yaml(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        yaml.safe_dump(value, output, sort_keys=False)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    if yaml.safe_load(path.read_text(encoding="utf-8")) != value:
        raise RuntimeError(f"persisted YAML readback mismatch: {path}")


def verify_inputs(manifest_path: Path) -> tuple[Path, list[InputPhoto], dict[str, Any]]:
    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    if manifest["schema"] != "pw_cross_photo_lossless_potential_inputs_v1":
        raise RuntimeError("input manifest schema mismatch")
    root = Path(manifest["source_root"])
    photos: list[InputPhoto] = []
    for sidecar in manifest["sidecars"]:
        path = root / sidecar["name"]
        if path.stat().st_size != sidecar["bytes"]:
            raise RuntimeError(f"input size drift: {path}")
        if sha256_file(path) != sidecar["sha256"]:
            raise RuntimeError(f"input SHA-256 drift: {path}")
    for registered in manifest["photos"]:
        path = root / "photos_highres" / registered["name"]
        if path.stat().st_size != registered["bytes"]:
            raise RuntimeError(f"input size drift: {path}")
        if sha256_file(path) != registered["sha256"]:
            raise RuntimeError(f"input SHA-256 drift: {path}")
        photos.append(
            InputPhoto(
                index=registered["index"],
                name=registered["name"],
                path=path,
                bytes=registered["bytes"],
                sha256=registered["sha256"],
            )
        )
    if len(photos) != manifest["selection"]["selected_count"]:
        raise RuntimeError("input photo count differs from manifest")
    if sum(photo.bytes for photo in photos) != manifest["selection"]["selected_bytes"]:
        raise RuntimeError("input photo byte count differs from manifest")
    return root, photos, manifest


def run_checked(command: Sequence[object]) -> None:
    subprocess.run(
        [os.fspath(item) for item in command],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def read_bundle_frames(root: Path, photos: Sequence[InputPhoto]) -> list[dict[str, Any]]:
    decoded = json.loads(
        (root / "official_photo_bundle.json").read_text(encoding="utf-8")
    )
    frames = decoded["frames"][: len(photos)]
    if [frame["highresFilename"] for frame in frames] != [
        photo.name for photo in photos
    ]:
        raise RuntimeError("photo bundle order differs from frozen manifest")
    if any(
        frame["imageWidth"] != 4032 or frame["imageHeight"] != 3024
        for frame in frames
    ):
        raise RuntimeError("sample JPEG dimensions changed")
    return frames


def create_archive_frame(
    tool: Path,
    photo: InputPhoto,
    work: Path,
) -> ArchiveFrame:
    coefficient_path = work / f"{photo.index:03d}.pwc"
    run_checked((tool, "extract", photo.path, coefficient_path))
    jpeg = parse_pwc(coefficient_path.read_bytes())
    coefficient_path.unlink()
    return ArchiveFrame(
        index=photo.index,
        name=photo.name,
        source_bytes=photo.bytes,
        source_sha256=photo.sha256,
        jpeg=jpeg,
    )


def prediction_mappings(
    frames: Sequence[ArchiveFrame],
    bundle_frames: Sequence[dict[str, Any]],
    poses: dict[int, Any],
    points: Any,
) -> tuple[list[list[Any]], int, int, int]:
    mappings: list[list[Any]] = []
    valid_projections = 0
    covered_blocks = 0
    total_blocks = 0
    for reference, target in adjacent_pairs(frames):
        if reference.index not in poses or target.index not in poses:
            raise RuntimeError("registered SfM pose missing from sample")
        pair_maps, pair_valid, pair_covered, pair_total = (
            build_prediction_mappings(
                points,
                target_pose=poses[target.index],
                reference_pose=poses[reference.index],
                target_intrinsics=bundle_frames[target.index]["intrinsics"],
                reference_intrinsics=bundle_frames[reference.index]["intrinsics"],
                image_width=bundle_frames[target.index]["imageWidth"],
                image_height=bundle_frames[target.index]["imageHeight"],
                target_components=target.jpeg.components,
                reference_components=reference.jpeg.components,
            )
        )
        mappings.append(pair_maps)
        valid_projections += pair_valid
        covered_blocks += pair_covered
        total_blocks += pair_total
    return mappings, valid_projections, covered_blocks, total_blocks


def verify_restored_frame(
    tool: Path,
    restored_frame: ArchiveFrame,
    source: InputPhoto,
    work: Path,
) -> bool:
    coefficient_path = work / f"{source.index:03d}.restored.pwc"
    jpeg_path = work / f"{source.index:03d}.restored.jpg"
    coefficient_path.write_bytes(serialize_pwc(restored_frame.jpeg))
    run_checked((tool, "restore", coefficient_path, jpeg_path))
    valid = (
        jpeg_path.stat().st_size == source.bytes
        and files_equal(source.path, jpeg_path)
        and sha256_file(jpeg_path) == source.sha256
    )
    coefficient_path.unlink()
    jpeg_path.unlink()
    return valid


def corrupt_archive_is_rejected(
    archive: bytes,
    mappings: Sequence[Sequence[Any]],
) -> bool:
    corrupted = bytearray(archive)
    corrupted[len(corrupted) // 2] ^= 1
    try:
        payload = lzma.decompress(bytes(corrupted), format=lzma.FORMAT_XZ)
        decode_group_payload(payload, mappings)
    except (lzma.LZMAError, ValueError):
        return True
    return False


def run_jxl_baseline(
    photos: Sequence[InputPhoto],
    work: Path,
) -> dict[str, Any]:
    state = ArmState(
        name="jxl_effort_10_exact_baseline",
        source_jpeg_bytes=sum(photo.bytes for photo in photos),
    )
    archive_digest = hashlib.sha256()
    encode_started = time.perf_counter()
    for photo in photos:
        archive_path = work / f"{photo.index:03d}.jxl"
        restored_path = work / f"{photo.index:03d}.jxl-restored.jpg"
        run_checked(
            (
                "cjxl",
                photo.path,
                archive_path,
                "--lossless_jpeg=1",
                "--effort=10",
                "--quiet",
            )
        )
        state.archive_bytes += archive_path.stat().st_size
        archive_digest.update(bytes.fromhex(sha256_file(archive_path)))
        state.peak_temp_bytes = max(state.peak_temp_bytes, directory_bytes(work))
        if photo.index == photos[0].index:
            repeated_archive_path = work / "determinism-check.jxl"
            run_checked(
                (
                    "cjxl",
                    photo.path,
                    repeated_archive_path,
                    "--lossless_jpeg=1",
                    "--effort=10",
                    "--quiet",
                )
            )
            if not files_equal(archive_path, repeated_archive_path):
                state.deterministic_archive_hash = False
                raise RuntimeError("JXL archive is not deterministic")
            repeated_archive_path.unlink()
        encode_elapsed = time.perf_counter()
        run_checked(("djxl", archive_path, restored_path, "--quiet"))
        state.decode_elapsed_ms += (time.perf_counter() - encode_elapsed) * 1000
        if not (
            restored_path.stat().st_size == photo.bytes
            and files_equal(photo.path, restored_path)
            and sha256_file(restored_path) == photo.sha256
        ):
            state.exactness_failures += 1
            raise RuntimeError(f"JXL exactness failure: {photo.name}")
        archive_path.unlink()
        restored_path.unlink()
    state.encode_elapsed_ms = (
        (time.perf_counter() - encode_started) * 1000 - state.decode_elapsed_ms
    )
    state.corruption_rejected = True
    result = arm_result(state)
    result["archive_sha256"] = archive_digest.hexdigest()
    result["group_size"] = 1
    result["deterministic_archive_hash"] = True
    result["corruption_rejected"] = True
    return result


def run_group_arm(
    *,
    group_size: int,
    tool: Path,
    photos: Sequence[InputPhoto],
    bundle_frames: Sequence[dict[str, Any]],
    poses: dict[int, Any],
    points: Any,
    work: Path,
) -> dict[str, Any]:
    arm_name = f"sfm_coeff_group_{group_size}_xz9e"
    state = ArmState(
        name=arm_name,
        source_jpeg_bytes=sum(photo.bytes for photo in photos),
    )
    group_records: list[tuple[list[int], Path, list[list[Any]]]] = []
    archive_digest = hashlib.sha256()
    encode_started = time.perf_counter()
    for group_number, indices in enumerate(
        make_groups(list(range(len(photos))), group_size)
    ):
        group_work = work / f"group-{group_number:02d}"
        group_work.mkdir()
        archive_frames = [
            create_archive_frame(tool, photos[index], group_work)
            for index in indices
        ]
        mappings, valid, covered, total = prediction_mappings(
            archive_frames,
            bundle_frames,
            poses,
            points,
        )
        state.valid_sparse_projections += valid
        state.mapped_blocks += covered
        state.total_blocks += total
        payload = encode_group_payload(archive_frames, mappings)
        archive = lzma.compress(
            payload,
            format=lzma.FORMAT_XZ,
            check=lzma.CHECK_CRC64,
            preset=XZ_PRESET,
        )
        repeated_archive = lzma.compress(
            payload,
            format=lzma.FORMAT_XZ,
            check=lzma.CHECK_CRC64,
            preset=XZ_PRESET,
        )
        if repeated_archive != archive:
            state.deterministic_archive_hash = False
            raise RuntimeError(f"nondeterministic group archive: {group_number}")
        archive_path = work / f"group-{group_number:02d}.pwc.xz"
        archive_path.write_bytes(archive)
        state.archive_bytes += len(archive)
        archive_digest.update(bytes.fromhex(sha256_file(archive_path)))
        state.peak_temp_bytes = max(state.peak_temp_bytes, directory_bytes(work))
        if group_number == 0:
            state.corruption_rejected = corrupt_archive_is_rejected(
                archive,
                mappings,
            )
            if not state.corruption_rejected:
                raise RuntimeError("corrupted group archive was accepted")
        decode_started = time.perf_counter()
        decoded_payload = lzma.decompress(archive, format=lzma.FORMAT_XZ)
        decoded_frames = decode_group_payload(decoded_payload, mappings)
        for decoded, index in zip(decoded_frames, indices, strict=True):
            if not verify_restored_frame(tool, decoded, photos[index], group_work):
                state.exactness_failures += 1
                raise RuntimeError(f"exactness failure: {photos[index].name}")
        state.decode_elapsed_ms += (time.perf_counter() - decode_started) * 1000
        group_records.append((indices, archive_path, mappings))
        shutil.rmtree(group_work)
        del repeated_archive, archive, payload, decoded_payload, decoded_frames
        print(
            json.dumps(
                {
                    "event": "group_verified",
                    "arm": arm_name,
                    "group": group_number,
                    "frames": len(indices),
                    "archive_bytes_total": state.archive_bytes,
                },
                sort_keys=True,
            ),
            flush=True,
        )
        if ratio_threshold_impossible(
            source_total_bytes=state.source_jpeg_bytes,
            archive_bytes_so_far=state.archive_bytes,
            minimum_ratio=MINIMUM_RATIO,
        ):
            print(
                json.dumps(
                    {
                        "event": "arm_stopped_by_ratio_upper_bound",
                        "arm": arm_name,
                        "processed_photo_count": sum(
                            len(record[0]) for record in group_records
                        ),
                        "archive_bytes_so_far": state.archive_bytes,
                        "best_possible_photo_ratio": (
                            state.source_jpeg_bytes / state.archive_bytes
                        ),
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
            break
    state.encode_elapsed_ms = (
        (time.perf_counter() - encode_started) * 1000 - state.decode_elapsed_ms
    )

    audit_random = random.Random(RANDOM_ACCESS_SEED)
    processed_indices = [
        index for indices, _, _ in group_records for index in indices
    ]
    requested_indices = audit_random.sample(
        processed_indices,
        min(10, len(processed_indices)),
    )
    for requested in requested_indices:
        matching = [record for record in group_records if requested in record[0]]
        if len(matching) != 1:
            raise RuntimeError("random access did not resolve to exactly one group")
        indices, archive_path, mappings = matching[0]
        if len(indices) > group_size:
            state.random_access_group_overflow += 1
            raise RuntimeError("random access group exceeds configured bound")
        decoded_payload = lzma.decompress(
            archive_path.read_bytes(),
            format=lzma.FORMAT_XZ,
        )
        decoded = decode_group_payload(decoded_payload, mappings)
        local_index = indices.index(requested)
        if not verify_restored_frame(
            tool,
            decoded[local_index],
            photos[requested],
            work,
        ):
            state.exactness_failures += 1
            raise RuntimeError(f"random access exactness failure: {requested}")
    for _, archive_path, _ in group_records:
        archive_path.unlink()
    result = arm_result(state)
    result["archive_sha256"] = archive_digest.hexdigest()
    result["group_size"] = group_size
    result["deterministic_archive_hash"] = state.deterministic_archive_hash
    result["corruption_rejected"] = state.corruption_rejected
    result["random_access_requests"] = requested_indices
    result["random_access_max_decoded_frames"] = max(
        len(indices) for indices, _, _ in group_records
    )
    result["processed_photo_count"] = len(processed_indices)
    result["sample_photo_count"] = len(photos)
    result["early_stopped"] = len(processed_indices) < len(photos)
    result["photo_ratio_kind"] = (
        "zero-byte-remainder-theoretical-upper-bound"
        if result["early_stopped"]
        else "measured-full-sample"
    )
    result["full_archive_max_bytes_at_threshold"] = int(
        state.source_jpeg_bytes / MINIMUM_RATIO
    )
    result["unprocessed_assumed_archive_bytes_for_upper_bound"] = 0
    return result


def arm_result(state: ArmState) -> dict[str, Any]:
    peak_rss = max(
        resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
    )
    mapped_fraction = (
        state.mapped_blocks / state.total_blocks if state.total_blocks else 0.0
    )
    result = build_result(
        source_jpeg_bytes=state.source_jpeg_bytes,
        archive_bytes=state.archive_bytes,
        exactness_failures=state.exactness_failures,
        input_hash_failures=state.input_hash_failures,
        valid_sparse_projections=state.valid_sparse_projections,
        random_access_group_overflow=state.random_access_group_overflow,
        mapped_block_fraction=mapped_fraction,
        encode_elapsed_ms=state.encode_elapsed_ms,
        decode_elapsed_ms=state.decode_elapsed_ms,
        peak_rss_bytes=peak_rss,
    )
    result["arm"] = state.name
    result["peak_temp_bytes"] = state.peak_temp_bytes
    result["source_unchanged"] = state.source_unchanged
    result["threshold"] = MINIMUM_RATIO
    result["threshold_passed"] = result["photo_ratio"] >= MINIMUM_RATIO
    return result


def persist_result(
    *,
    scratch: Path,
    log: dict[str, Any],
    result: dict[str, Any],
) -> None:
    result_path = scratch / f"{result['arm']}.json"
    atomic_json(result_path, result)
    log["arms"].append(result)
    atomic_yaml(scratch / "experiment-log.yaml", log)
    with mlflow.start_run(run_name=result["arm"]):
        mlflow.log_params(
            {
                "arm": result["arm"],
                "group_size": result["group_size"],
                "minimum_photo_ratio": MINIMUM_RATIO,
                "random_access_seed": RANDOM_ACCESS_SEED,
            }
        )
        numeric_metrics = {
            key: value
            for key, value in result.items()
            if isinstance(value, (int, float)) and not isinstance(value, bool)
        }
        mlflow.log_metrics(numeric_metrics)
        mlflow.set_tags(
            {
                "evidence_role": "host-feasibility-and-rejection-only",
                "exactness": "byte-and-sha256",
                "production_modified": "false",
            }
        )
    marker = scratch / f"{result['arm']}.persisted"
    marker.write_text(
        hashlib.sha256(result_path.read_bytes()).hexdigest() + "\n",
        encoding="utf-8",
    )


def load_persisted_result(
    scratch: Path,
    arm_name: str,
) -> dict[str, Any] | None:
    result_path = scratch / f"{arm_name}.json"
    marker = scratch / f"{arm_name}.persisted"
    if not result_path.exists() and not marker.exists():
        return None
    if not result_path.is_file() or not marker.is_file():
        raise RuntimeError(f"incomplete persisted arm marker: {arm_name}")
    expected_hash = marker.read_text(encoding="utf-8").strip()
    if sha256_file(result_path) != expected_hash:
        raise RuntimeError(f"persisted arm hash mismatch: {arm_name}")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if result.get("arm") != arm_name:
        raise RuntimeError(f"persisted arm identity mismatch: {arm_name}")
    if result.get("exactness_failures") != 0 or not result.get("source_unchanged"):
        raise RuntimeError(f"persisted arm did not pass hard gates: {arm_name}")
    return result


def source_hashes(photos: Sequence[InputPhoto]) -> dict[str, str]:
    return {photo.name: sha256_file(photo.path) for photo in photos}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jpeg-coeff-tool", type=Path, required=True)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("input-manifest.yaml"),
    )
    arguments = parser.parse_args()

    experiment_dir = Path(__file__).resolve().parent
    repo_root = experiment_dir.parents[1]
    scratch = (
        repo_root
        / ".context/compound-engineering/ce-optimize/"
        "cross-photo-lossless-potential"
    )
    scratch.mkdir(parents=True, exist_ok=True)
    tracking_database = scratch / "mlflow.db"
    mlflow.set_tracking_uri(f"sqlite:///{tracking_database}")
    mlflow.set_experiment("cross-photo-lossless-potential")

    root, photos, manifest = verify_inputs(arguments.manifest)
    before_hashes = source_hashes(photos)
    bundle_frames = read_bundle_frames(root, photos)
    poses = load_registered_poses(root / "official_sfm_sparse_meta.json")
    points = load_binary_ply_xyz(root / "official_sfm_sparse.ply")
    experiment_log_path = scratch / "experiment-log.yaml"
    if experiment_log_path.exists():
        log = yaml.safe_load(experiment_log_path.read_text(encoding="utf-8"))
        if (
            log.get("schema") != "ce_optimize_experiment_log_v1"
            or log.get("experiment") != "cross-photo-lossless-potential"
        ):
            raise RuntimeError("existing experiment log identity mismatch")
        log.setdefault("resumed_at", []).append(
            datetime.now(timezone.utc).isoformat()
        )
        log["status"] = "running"
    else:
        log = {
            "schema": "ce_optimize_experiment_log_v1",
            "experiment": "cross-photo-lossless-potential",
            "started_at": datetime.now(timezone.utc).isoformat(),
            "contract_sha256": sha256_file(
                experiment_dir / "experiment-contract.yaml"
            ),
            "input_manifest_sha256": sha256_file(arguments.manifest),
            "input_count": len(photos),
            "input_bytes": sum(photo.bytes for photo in photos),
            "input_selection": manifest["selection"]["rule"],
            "arms": [],
            "status": "running",
        }
    atomic_yaml(scratch / "experiment-log.yaml", log)

    with tempfile.TemporaryDirectory(
        prefix="pw-cross-photo-benchmark-",
        dir="/private/tmp",
    ) as temporary:
        work_root = Path(temporary)
        arms: list[dict[str, Any]] = []

        jxl_result = load_persisted_result(
            scratch,
            "jxl_effort_10_exact_baseline",
        )
        if jxl_result is None:
            jxl_work = work_root / "jxl-effort-10"
            jxl_work.mkdir()
            jxl_result = run_jxl_baseline(photos, jxl_work)
            after_hashes = source_hashes(photos)
            jxl_result["source_unchanged"] = after_hashes == before_hashes
            if not jxl_result["source_unchanged"]:
                raise RuntimeError("immutable source changed during JXL arm")
            persist_result(scratch=scratch, log=log, result=jxl_result)
            print(json.dumps({"event": "arm_persisted", **jxl_result}), flush=True)
        else:
            print(
                json.dumps(
                    {"event": "arm_resumed_from_verified_result", **jxl_result}
                ),
                flush=True,
            )
        arms.append(jxl_result)

        for group_size in (4, 8):
            arm_name = f"sfm_coeff_group_{group_size}_xz9e"
            result = load_persisted_result(
                scratch,
                arm_name,
            )
            if result is None:
                arm_work = work_root / f"group-{group_size}"
                arm_work.mkdir()
                result = run_group_arm(
                    group_size=group_size,
                    tool=arguments.jpeg_coeff_tool,
                    photos=photos,
                    bundle_frames=bundle_frames,
                    poses=poses,
                    points=points,
                    work=arm_work,
                )
                after_hashes = source_hashes(photos)
                result["source_unchanged"] = after_hashes == before_hashes
                if not result["source_unchanged"]:
                    raise RuntimeError("immutable source changed during group arm")
                persist_result(scratch=scratch, log=log, result=result)
                print(json.dumps({"event": "arm_persisted", **result}), flush=True)
            else:
                print(
                    json.dumps(
                        {"event": "arm_resumed_from_verified_result", **result}
                    ),
                    flush=True,
                )
            arms.append(result)

    group_results = [
        result for result in arms if result["arm"].startswith("sfm_coeff_group_")
    ]
    if any(result["threshold_passed"] for result in group_results):
        verdict = "eligible-for-independent-phone-bundle"
    else:
        verdict = "reject-before-phone"
    log["status"] = "complete"
    log["completed_at"] = datetime.now(timezone.utc).isoformat()
    log["verdict"] = verdict
    atomic_yaml(scratch / "experiment-log.yaml", log)
    digest = scratch / "strategy-digest.md"
    digest.write_text(
        "\n".join(
            (
                "# Cross-photo lossless potential",
                "",
                f"Verdict: `{verdict}`.",
                "",
                *[
                    (
                        f"- `{result['arm']}`: "
                        f"{result['photo_ratio']:.6f}x, "
                        f"{result['archive_bytes']} bytes, "
                        f"exactness failures {result['exactness_failures']}."
                    )
                    for result in arms
                ],
                "",
                "Host evidence is rejection/feasibility evidence only. It does "
                "not select or approve a production implementation.",
                "",
            )
        ),
        encoding="utf-8",
    )
    print(json.dumps({"event": "experiment_complete", "verdict": verdict}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
