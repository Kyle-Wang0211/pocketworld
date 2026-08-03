"""Deterministically select and verify an Open Images original-JPEG corpus."""

from __future__ import annotations

import base64
import csv
import hashlib
import heapq
import json
import os
from pathlib import Path
import re
import subprocess
import time
from typing import Callable, Iterable, TextIO
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


CC_BY_2 = "https://creativecommons.org/licenses/by/2.0/"


def _selection_score(seed: str, image_id: str) -> str:
    return hashlib.sha256(f"{seed}:{image_id}".encode()).hexdigest()


def assign_final_splits(
    images: list[dict[str, object]],
    *,
    split_seed: str,
    split_counts: dict[str, int],
) -> list[dict[str, object]]:
    """Assign exact deterministic split counts without depending on input order."""
    if not split_seed:
        raise ValueError("split_seed must not be empty")
    if not split_counts or any(count < 0 for count in split_counts.values()):
        raise ValueError("split counts must be non-negative")
    if sum(split_counts.values()) != len(images):
        raise ValueError("split counts total must equal image count")

    scored: list[tuple[str, str, dict[str, object]]] = []
    seen_ids: set[str] = set()
    for image in images:
        image_id = str(image["image_id"])
        if image_id in seen_ids:
            raise ValueError(f"duplicate Open Images ID: {image_id}")
        seen_ids.add(image_id)
        scored.append(
            (_selection_score(split_seed, image_id), image_id, dict(image))
        )
    scored.sort(key=lambda item: (item[0], item[1]))

    offset = 0
    assigned: list[dict[str, object]] = []
    for split, count in split_counts.items():
        for score, _, image in scored[offset : offset + count]:
            image["split"] = split
            image["split_score"] = score
            assigned.append(image)
        offset += count

    if assigned and all("selection_rank" in image for image in assigned):
        assigned.sort(key=lambda image: int(image["selection_rank"]))
    else:
        assigned.sort(key=lambda image: str(image["image_id"]))
    return assigned


def parse_cvdf_listing(
    payload: bytes,
) -> tuple[list[dict[str, object]], str | None]:
    """Parse one anonymous Open Images CVDF S3 ListObjectsV2 response."""
    root = ET.fromstring(payload)
    namespace = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
    items: list[dict[str, object]] = []
    for content in root.findall("s3:Contents", namespace):
        key = content.findtext("s3:Key", namespaces=namespace)
        etag = content.findtext("s3:ETag", namespaces=namespace)
        size = content.findtext("s3:Size", namespaces=namespace)
        if key is None or etag is None or size is None:
            raise ValueError("incomplete CVDF S3 listing entry")
        match = re.fullmatch(r"train/([0-9a-fA-F]{16})\.jpg", key)
        if match is None:
            continue
        normalized_etag = etag.strip('"').lower()
        if re.fullmatch(r"[0-9a-f]{32}", normalized_etag) is None:
            raise ValueError(f"unsupported multipart or invalid ETag for {key}")
        items.append(
            {
                "image_id": match.group(1).lower(),
                "cvdf_key": key,
                "cvdf_bytes": int(size),
                "cvdf_etag_md5": normalized_etag,
                "cvdf_url": (
                    "https://open-images-dataset.s3.amazonaws.com/" + key
                ),
            }
        )
    truncated = root.findtext("s3:IsTruncated", namespaces=namespace)
    token = root.findtext("s3:NextContinuationToken", namespaces=namespace)
    if truncated == "true" and not token:
        raise ValueError("truncated CVDF listing is missing continuation token")
    return items, token if truncated == "true" else None


def select_cvdf_candidates(
    items: Iterable[dict[str, object]],
    *,
    candidate_count: int,
    selection_seed: str,
) -> list[dict[str, object]]:
    """Select the globally lowest deterministic hashes from a CVDF listing."""
    if candidate_count <= 0:
        raise ValueError("candidate_count must be positive")
    if not selection_seed:
        raise ValueError("selection_seed must not be empty")
    selected: list[tuple[int, str, dict[str, object]]] = []
    seen_ids: set[str] = set()
    for item in items:
        image_id = str(item["image_id"])
        if image_id in seen_ids:
            raise ValueError(f"duplicate Open Images ID: {image_id}")
        seen_ids.add(image_id)
        score = _selection_score(selection_seed, image_id)
        score_value = int(score, 16)
        candidate = {**item, "selection_score": score}
        heap_item = (-score_value, image_id, candidate)
        if len(selected) < candidate_count:
            heapq.heappush(selected, heap_item)
        elif score_value < -selected[0][0]:
            heapq.heapreplace(selected, heap_item)
    if len(selected) != candidate_count:
        raise ValueError(
            f"CVDF listing produced {len(selected)} candidates; "
            f"expected {candidate_count}"
        )
    result = [item for _, _, item in selected]
    result.sort(key=lambda item: (str(item["selection_score"]), str(item["image_id"])))
    for rank, item in enumerate(result, start=1):
        item["selection_rank"] = rank
    return result


def enrich_cvdf_candidates(
    source: TextIO,
    candidates: list[dict[str, object]],
    *,
    require_all: bool = True,
) -> list[dict[str, object]]:
    """Join CVDF candidates to the official attribution/license metadata."""
    candidates_by_id = {str(item["image_id"]): item for item in candidates}
    if len(candidates_by_id) != len(candidates):
        raise ValueError("duplicate Open Images ID in CVDF candidates")
    enriched: dict[str, dict[str, object]] = {}
    for row in csv.DictReader(source):
        image_id = row.get("ImageID", "")
        candidate = candidates_by_id.get(image_id)
        if candidate is None:
            continue
        if image_id in enriched:
            raise ValueError(f"duplicate Open Images metadata row: {image_id}")
        if row.get("Subset") != "train" or row.get("License") != CC_BY_2:
            continue
        metadata = _candidate(row, str(candidate["selection_score"]))
        enriched[image_id] = {**metadata, **candidate}
    missing = sorted(set(candidates_by_id) - set(enriched))
    if missing and require_all:
        raise ValueError(
            f"{len(missing)} CVDF candidates lack eligible metadata; "
            f"first missing ID: {missing[0]}"
        )
    result = list(enriched.values())
    result.sort(key=lambda item: int(item["selection_rank"]))
    return result


def _candidate(row: dict[str, str], score: str) -> dict[str, object]:
    return {
        "image_id": row["ImageID"],
        "subset": row["Subset"],
        "original_url": row["OriginalURL"],
        "original_landing_url": row["OriginalLandingURL"],
        "license": row["License"],
        "author_profile_url": row["AuthorProfileURL"],
        "author": row["Author"],
        "title": row["Title"],
        "original_bytes": int(row["OriginalSize"]),
        "original_md5_base64": row["OriginalMD5"],
        "rotation": row["Rotation"],
        "selection_score": score,
    }


def select_metadata_candidates(
    source: TextIO,
    *,
    candidate_count: int,
    selection_seed: str,
    minimum_original_bytes: int,
    maximum_original_bytes: int,
) -> list[dict[str, object]]:
    """Return the lowest deterministic hash ranks among eligible metadata rows."""
    if candidate_count <= 0:
        raise ValueError("candidate_count must be positive")
    if not 0 < minimum_original_bytes <= maximum_original_bytes:
        raise ValueError("invalid original-byte bounds")

    selected: list[tuple[int, str, dict[str, object]]] = []
    seen_ids: set[str] = set()
    for row in csv.DictReader(source):
        image_id = row.get("ImageID", "")
        if image_id in seen_ids:
            raise ValueError(f"duplicate Open Images ID: {image_id}")
        seen_ids.add(image_id)
        if row.get("Subset") != "train" or row.get("License") != CC_BY_2:
            continue
        original_url = row.get("OriginalURL", "")
        landing_url = row.get("OriginalLandingURL", "")
        if not original_url.startswith("https://") or not landing_url.startswith(
            "https://"
        ):
            continue
        try:
            original_bytes = int(row.get("OriginalSize", ""))
            decoded_md5 = base64.b64decode(
                row.get("OriginalMD5", ""),
                validate=True,
            )
        except (ValueError, TypeError):
            continue
        if len(decoded_md5) != 16:
            continue
        if not minimum_original_bytes <= original_bytes <= maximum_original_bytes:
            continue

        score = _selection_score(selection_seed, image_id)
        score_value = int(score, 16)
        item = _candidate(row, score)
        heap_item = (-score_value, image_id, item)
        if len(selected) < candidate_count:
            heapq.heappush(selected, heap_item)
        elif score_value < -selected[0][0]:
            heapq.heapreplace(selected, heap_item)

    if len(selected) != candidate_count:
        raise ValueError(
            f"eligible metadata rows produced {len(selected)} candidates; "
            f"expected {candidate_count}"
        )
    result = [item for _, _, item in selected]
    result.sort(key=lambda item: (str(item["selection_score"]), str(item["image_id"])))
    for rank, item in enumerate(result, start=1):
        item["selection_rank"] = rank
    return result


def fetch_url_with_retries(
    url: str,
    *,
    attempts: int = 5,
    opener: Callable[..., object] = urllib.request.urlopen,
    sleep: Callable[[float], None] = time.sleep,
) -> bytes:
    if attempts <= 0:
        raise ValueError("download attempts must be positive")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "PocketWorld-PLR-Research/1.0"},
    )
    for attempt in range(attempts):
        try:
            with opener(request, timeout=12) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            if attempt + 1 == attempts:
                raise
            sleep(0.25 * (2**attempt))
    raise AssertionError("unreachable retry state")


def _fetch_url(url: str) -> bytes:
    return fetch_url_with_retries(url)


def _verify_payload(candidate: dict[str, object], payload: bytes) -> str:
    image_id = str(candidate["image_id"])
    if len(payload) != int(candidate["original_bytes"]):
        raise ValueError(f"OriginalSize mismatch for {image_id}")
    actual_md5 = base64.b64encode(hashlib.md5(payload).digest()).decode()
    if actual_md5 != candidate["original_md5_base64"]:
        raise ValueError(f"OriginalMD5 mismatch for {image_id}")
    if not payload.startswith(b"\xff\xd8") or not payload.endswith(b"\xff\xd9"):
        raise ValueError(f"original payload is not a complete JPEG: {image_id}")
    return hashlib.sha256(payload).hexdigest()


def download_candidate(
    candidate: dict[str, object],
    output_directory: Path,
    *,
    fetch: Callable[[str], bytes] = _fetch_url,
) -> dict[str, object]:
    output_directory.mkdir(parents=True, exist_ok=True)
    image_id = str(candidate["image_id"])
    final_path = output_directory / f"{image_id}.jpg"
    temporary_path = output_directory / f".{image_id}.jpg.tmp"
    temporary_path.unlink(missing_ok=True)
    if final_path.is_file():
        payload = final_path.read_bytes()
        sha256 = _verify_payload(candidate, payload)
        return {
            **candidate,
            "status": "reused_verified",
            "path": str(final_path),
            "bytes": len(payload),
            "sha256": sha256,
        }
    payload = fetch(str(candidate["original_url"]))
    try:
        sha256 = _verify_payload(candidate, payload)
        temporary_path.write_bytes(payload)
        os.replace(temporary_path, final_path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise
    return {
        **candidate,
        "status": "downloaded_verified",
        "path": str(final_path),
        "bytes": len(payload),
        "sha256": sha256,
    }


def _verify_cvdf_payload(candidate: dict[str, object], payload: bytes) -> str:
    image_id = str(candidate["image_id"])
    if len(payload) != int(candidate["cvdf_bytes"]):
        raise ValueError(f"CVDF listing size mismatch for {image_id}")
    actual_md5 = hashlib.md5(payload).hexdigest()
    if actual_md5 != str(candidate["cvdf_etag_md5"]).lower():
        raise ValueError(f"CVDF listing ETag mismatch for {image_id}")
    if not payload.startswith(b"\xff\xd8") or not payload.endswith(b"\xff\xd9"):
        raise ValueError(f"CVDF payload is not a complete JPEG: {image_id}")
    return hashlib.sha256(payload).hexdigest()


def download_cvdf_candidate(
    candidate: dict[str, object],
    output_directory: Path,
    *,
    fetch: Callable[[str], bytes] = _fetch_url,
) -> dict[str, object]:
    """Download or revalidate one official CVDF mirror JPEG."""
    output_directory.mkdir(parents=True, exist_ok=True)
    image_id = str(candidate["image_id"])
    final_path = output_directory / f"{image_id}.jpg"
    temporary_path = output_directory / f".{image_id}.jpg.tmp"
    temporary_path.unlink(missing_ok=True)
    if final_path.is_file():
        payload = final_path.read_bytes()
        sha256 = _verify_cvdf_payload(candidate, payload)
        return {
            **candidate,
            "status": "reused_verified",
            "path": str(final_path),
            "bytes": len(payload),
            "sha256": sha256,
        }
    payload = fetch(str(candidate["cvdf_url"]))
    try:
        sha256 = _verify_cvdf_payload(candidate, payload)
        temporary_path.write_bytes(payload)
        os.replace(temporary_path, final_path)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise
    return {
        **candidate,
        "status": "downloaded_verified",
        "path": str(final_path),
        "bytes": len(payload),
        "sha256": sha256,
    }


def probe_cvdf_jpeg(
    downloaded: dict[str, object],
    probe_binary: Path,
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, object]:
    """Attach exact JPEG geometry while preserving the verified source identity."""
    completed = run(
        [str(probe_binary), "--probe", str(downloaded["path"])],
        check=True,
        capture_output=True,
        text=True,
    )
    try:
        probe = json.loads(completed.stdout)
    except (json.JSONDecodeError, TypeError) as error:
        raise ValueError(
            f"invalid JPEG probe output for {downloaded['image_id']}"
        ) from error
    if int(probe["source_bytes"]) != int(downloaded["bytes"]):
        raise ValueError(
            f"probe byte-count mismatch for {downloaded['image_id']}"
        )
    if str(probe["source_sha256"]) != str(downloaded["sha256"]):
        raise ValueError(f"probe SHA-256 mismatch for {downloaded['image_id']}")
    return {
        **downloaded,
        "eligible_plr_420": bool(probe["eligible_plr_420"]),
        "jpeg_width": int(probe["width"]),
        "jpeg_height": int(probe["height"]),
        "luma_width_in_blocks": int(probe["luma_width_in_blocks"]),
        "luma_height_in_blocks": int(probe["luma_height_in_blocks"]),
        "jpeg_component_count": int(probe["component_count"]),
        "jpeg_subsampling": str(probe["subsampling"]),
    }


def download_and_probe_cvdf_candidate(
    candidate: dict[str, object],
    output_directory: Path,
    probe_binary: Path,
    *,
    fetch: Callable[[str], bytes] = _fetch_url,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, object]:
    """Download, verify, and structurally probe one candidate in one worker."""
    downloaded = download_cvdf_candidate(
        candidate,
        output_directory,
        fetch=fetch,
    )
    return probe_cvdf_jpeg(downloaded, probe_binary, run=run)
