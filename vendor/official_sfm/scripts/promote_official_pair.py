#!/usr/bin/env python3
"""Crash-recoverable promotion of the official carrier/framework pair."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
from typing import Any


SCHEMA = "PWOFFICIAL_P3_PAIR_TRANSACTION_V1"
CRASH_EXIT_CODE = 86
IMMUTABLE_ARGUMENTS = (
    ("Dawn archive", "dawn_archive", "expected_dawn_sha256"),
    ("Ceres archive", "ceres_archive", "expected_ceres_sha256"),
    ("glog archive", "glog_archive", "expected_glog_sha256"),
    ("iPhoneOS sqlite3 stub", "sqlite_tbd", "expected_sqlite_tbd_sha256"),
)


class PromotionError(RuntimeError):
    pass


def require_canonical_existing(path_text: str, label: str) -> Path:
    lexical = Path(path_text)
    if not lexical.is_absolute():
        raise PromotionError(f"{label} must be absolute: {lexical}")
    try:
        resolved = lexical.resolve(strict=True)
    except OSError as error:
        raise PromotionError(f"cannot resolve {label}: {error}") from error
    if lexical != resolved:
        raise PromotionError(f"{label} must not use traversal or symlink aliases: {lexical}")
    return resolved


def require_task_root(path_text: str, product_root: Path) -> Path:
    task_root = require_canonical_existing(path_text, "task root")
    private_tmp = Path("/private/tmp").resolve(strict=True)
    if task_root == private_tmp or private_tmp not in task_root.parents:
        raise PromotionError("task root must be a child of real /private/tmp")
    fixture_mode = (product_root / ".pwofficial-promotion-fixture-v1").is_file()
    if fixture_mode:
        if product_root not in task_root.parents:
            raise PromotionError("fixture task root must stay inside the fixture root")
    else:
        if task_root == product_root or product_root in task_root.parents:
            raise PromotionError("task root must be outside the product root")
        if task_root in product_root.parents:
            raise PromotionError("task root must not contain the product root")
    return task_root


def require_under_task_root(path_text: str, task_root: Path, label: str) -> Path:
    path = require_canonical_existing(path_text, label)
    if path == task_root or task_root not in path.parents:
        raise PromotionError(f"{label} must be below the task root")
    return path


def sha256_path(path: Path) -> str:
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    if not path.is_dir():
        raise PromotionError(f"not a file or directory: {path}")
    digest = hashlib.sha256()
    for entry in sorted(path.rglob("*"), key=lambda item: item.relative_to(path).as_posix()):
        relative = entry.relative_to(path).as_posix().encode()
        if entry.is_symlink():
            digest.update(
                b"L\0"
                + relative
                + b"\0"
                + entry.readlink().as_posix().encode()
                + b"\n"
            )
        elif entry.is_file():
            digest.update(b"F\0" + relative + b"\0")
            digest.update(hashlib.sha256(entry.read_bytes()).digest())
            digest.update(b"\n")
    return digest.hexdigest()


def require_sha256(path: Path, expected: str, label: str) -> None:
    actual = sha256_path(path)
    if actual != expected:
        raise PromotionError(f"{label} SHA-256 mismatch: expected {expected}, got {actual}")


def immutable_inputs_from_args(
    args: argparse.Namespace,
) -> tuple[tuple[str, Path, str], ...]:
    return tuple(
        (
            label,
            require_canonical_existing(getattr(args, path_name), label),
            getattr(args, digest_name),
        )
        for label, path_name, digest_name in IMMUTABLE_ARGUMENTS
    )


def immutable_inputs_from_record(
    record: dict[str, Any],
) -> tuple[tuple[str, Path, str], ...]:
    raw_inputs = record.get("immutable_inputs")
    if not isinstance(raw_inputs, list) or len(raw_inputs) != len(IMMUTABLE_ARGUMENTS):
        raise PromotionError("transaction journal immutable-input set is invalid")
    expected_labels = [item[0] for item in IMMUTABLE_ARGUMENTS]
    parsed: list[tuple[str, Path, str]] = []
    for expected_label, raw in zip(expected_labels, raw_inputs):
        if not isinstance(raw, dict) or raw.get("label") != expected_label:
            raise PromotionError("transaction journal immutable-input order is invalid")
        path_text = raw.get("path")
        digest = raw.get("sha256")
        if not isinstance(path_text, str) or not isinstance(digest, str):
            raise PromotionError("transaction journal immutable-input fields are invalid")
        lexical = Path(path_text)
        if (
            not lexical.is_absolute()
            or ".." in lexical.parts
            or str(lexical) != path_text
        ):
            raise PromotionError(
                "transaction journal immutable-input path is not canonical"
            )
        parsed.append((expected_label, lexical, digest))
    return tuple(parsed)


def verify_immutable_inputs(
    inputs: tuple[tuple[str, Path, str], ...], context: str
) -> None:
    for label, path, expected in inputs:
        canonical = require_canonical_existing(str(path), label)
        if canonical != path:
            raise PromotionError(f"{label} changed canonical identity: {path}")
        require_sha256(canonical, expected, f"{label} {context}")


def immutable_input_record(
    inputs: tuple[tuple[str, Path, str], ...]
) -> list[dict[str, str]]:
    return [
        {"label": label, "path": str(path), "sha256": expected}
        for label, path, expected in inputs
    ]


def fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_tree(path: Path) -> None:
    if path.is_file():
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        fsync_directory(path.parent)
        return
    directories = [path]
    for entry in path.rglob("*"):
        if entry.is_file() and not entry.is_symlink():
            fd = os.open(entry, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        elif entry.is_dir():
            directories.append(entry)
    for directory in reversed(directories):
        fsync_directory(directory)


def remove_non_live(path: Path, live_paths: set[Path]) -> None:
    if path in live_paths:
        raise PromotionError(f"refusing to delete a live path: {path}")
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def copy_candidate(source: Path, staging: Path, live_paths: set[Path]) -> None:
    if staging.exists() or staging.is_symlink():
        raise PromotionError(f"refusing existing staging path: {staging}")
    if source.is_file():
        shutil.copy2(source, staging)
    elif source.is_dir():
        shutil.copytree(source, staging, symlinks=True)
    else:
        raise PromotionError(f"candidate is not a file or directory: {source}")
    fsync_tree(staging)
    fsync_directory(staging.parent)
    if staging in live_paths:
        raise PromotionError(f"staging path aliases a live path: {staging}")


class Paths:
    def __init__(self, root: Path) -> None:
        self.root = root
        official = root / "vendor/official_sfm"
        self.live_carrier = official / "libs/ios-arm64/libpwofficial_gpu_extract.a"
        self.live_framework = official / "Frameworks/PWOfficialSfm.xcframework"
        self.self_carrier = (
            root / "vendor/aether_ffi/libs/ios-arm64/sfm/libpwsfm_gpu_extract.a"
        )
        self.core_archive = official / "libs/ios-arm64/libpwofficial_core.a"
        self.journal = official / ".pwofficial_pair_transaction_v1.json"
        self.journal_temporary = official / ".pwofficial_pair_transaction_v1.json.tmp"
        if (root / ".pwofficial-promotion-fixture-v1").is_file():
            self.lock = root / ".pwofficial_pair_transaction_v1.lock"
        else:
            root_key = hashlib.sha256(str(root).encode()).hexdigest()[:20]
            self.lock = Path("/private/tmp") / f"pwofficial-pair-{root_key}.lock"
        self.carrier_stage = self.live_carrier.with_name(
            "libpwofficial_gpu_extract.a.p3candidate"
        )
        self.carrier_backup = self.live_carrier.with_name(
            "libpwofficial_gpu_extract.a.p3backup"
        )
        self.framework_stage = self.live_framework.with_name(
            "PWOfficialSfm.xcframework.p3candidate"
        )
        self.framework_backup = self.live_framework.with_name(
            "PWOfficialSfm.xcframework.p3backup"
        )
        self.carrier_discard = self.live_carrier.with_name(
            "libpwofficial_gpu_extract.a.p3discard"
        )
        self.framework_discard = self.live_framework.with_name(
            "PWOfficialSfm.xcframework.p3discard"
        )

    @property
    def live_paths(self) -> set[Path]:
        return {
            self.live_carrier,
            self.live_framework,
            self.self_carrier,
            self.core_archive,
        }

    @property
    def temporary_paths(self) -> tuple[Path, ...]:
        return (
            self.journal_temporary,
            self.carrier_stage,
            self.carrier_backup,
            self.framework_stage,
            self.framework_backup,
            self.carrier_discard,
            self.framework_discard,
        )


def resolve_product_root(script: Path) -> Path:
    test_root = os.environ.get("PWOFFICIAL_TEST_PRODUCT_ROOT")
    if test_root:
        if os.environ.get("PWOFFICIAL_TEST_MODE") != "1":
            raise PromotionError("fixture root requires PWOFFICIAL_TEST_MODE=1")
        root = require_canonical_existing(test_root, "fixture product root")
        private_tmp = Path("/private/tmp").resolve(strict=True)
        if private_tmp not in root.parents:
            raise PromotionError("fixture product root must be under real /private/tmp")
        if not any(parent.name.startswith("pwofficial-promotion-fixture.") for parent in root.parents):
            raise PromotionError("fixture product root is outside the test-owned suite")
        marker = root / ".pwofficial-promotion-fixture-v1"
        if not marker.is_file():
            raise PromotionError(
                "PWOFFICIAL_TEST_PRODUCT_ROOT requires the fixture marker"
            )
        return root
    if (
        os.environ.get("PWOFFICIAL_TEST_FAIL_AFTER")
        or os.environ.get("PWOFFICIAL_TEST_CRASH_AFTER")
        or os.environ.get("PWOFFICIAL_TEST_DRIFT_IMMUTABLE_AT")
    ):
        raise PromotionError("fault injection is forbidden outside a marked fixture")
    return script.resolve(strict=True).parents[3]


def write_journal(path: Path, record: dict[str, Any]) -> None:
    temporary = path.with_name(path.name + ".tmp")
    if temporary.exists():
        temporary.unlink()
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(record, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
        injected_crash("journal_tmp_fsynced")
    os.replace(temporary, path)
    fsync_directory(path.parent)


def read_journal(path: Path) -> dict[str, Any]:
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PromotionError(f"cannot read transaction journal: {error}") from error
    if record.get("schema") != SCHEMA:
        raise PromotionError("transaction journal schema mismatch")
    return record


def set_phase(paths: Paths, record: dict[str, Any], phase: str) -> None:
    record["phase"] = phase
    write_journal(paths.journal, record)


def injected_failure(checkpoint: str) -> None:
    if os.environ.get("PWOFFICIAL_TEST_FAIL_AFTER") == checkpoint:
        raise PromotionError(f"injected handled failure after {checkpoint}")


def injected_crash(checkpoint: str) -> None:
    if os.environ.get("PWOFFICIAL_TEST_CRASH_AFTER") == checkpoint:
        os._exit(CRASH_EXIT_CODE)


def injected_immutable_drift(
    checkpoint: str, inputs: tuple[tuple[str, Path, str], ...]
) -> None:
    if os.environ.get("PWOFFICIAL_TEST_DRIFT_IMMUTABLE_AT") != checkpoint:
        return
    path = inputs[0][1]
    with path.open("ab") as stream:
        stream.write(b"injected immutable-input drift\n")
        stream.flush()
        os.fsync(stream.fileno())
    fsync_directory(path.parent)


def move_live_to_backup(live: Path, backup: Path) -> None:
    if backup.exists() or backup.is_symlink():
        raise PromotionError(f"refusing existing backup path: {backup}")
    os.replace(live, backup)
    fsync_directory(live.parent)


def install_stage(stage: Path, live: Path) -> None:
    os.replace(stage, live)
    fsync_directory(live.parent)


def restore_one(
    live: Path,
    backup: Path,
    discard: Path,
    expected_old_sha256: str,
    live_paths: set[Path],
) -> None:
    if backup.exists() or backup.is_symlink():
        require_sha256(backup, expected_old_sha256, f"backup {backup.name}")
        if discard.exists() or discard.is_symlink():
            remove_non_live(discard, live_paths)
        if live.exists() or live.is_symlink():
            os.replace(live, discard)
            fsync_directory(live.parent)
        os.replace(backup, live)
        fsync_directory(live.parent)
        if discard.exists() or discard.is_symlink():
            remove_non_live(discard, live_paths)
            fsync_directory(discard.parent)
    require_sha256(live, expected_old_sha256, f"restored {live.name}")


def cleanup_temporary(paths: Paths) -> None:
    for path in paths.temporary_paths:
        if path.exists() or path.is_symlink():
            remove_non_live(path, paths.live_paths)
            fsync_directory(path.parent)


def remove_journal(paths: Paths) -> None:
    if paths.journal.exists():
        paths.journal.unlink()
        fsync_directory(paths.journal.parent)


def recover(paths: Paths) -> None:
    if not paths.journal.exists():
        dangerous = [
            path
            for path in (
                paths.carrier_stage,
                paths.carrier_backup,
                paths.framework_stage,
                paths.framework_backup,
                paths.carrier_discard,
                paths.framework_discard,
            )
            if path.exists() or path.is_symlink()
        ]
        if dangerous:
            raise PromotionError(
                "promotion paths exist without a recoverable journal: "
                + ", ".join(str(path) for path in dangerous)
            )
        if paths.journal_temporary.exists() or paths.journal_temporary.is_symlink():
            remove_non_live(paths.journal_temporary, paths.live_paths)
            fsync_directory(paths.journal_temporary.parent)
        return

    record = read_journal(paths.journal)
    immutable_inputs = immutable_inputs_from_record(record)
    if record["phase"] == "committed":
        require_sha256(
            paths.live_carrier,
            record["candidate_carrier_sha256"],
            "committed live carrier",
        )
        require_sha256(
            paths.live_framework,
            record["candidate_framework_sha256"],
            "committed live framework",
        )
        require_sha256(
            paths.core_archive,
            record["core_sha256"],
            "frozen official core after commit",
        )
        require_sha256(
            paths.self_carrier,
            record["preserve_sha256"],
            "frozen self carrier after commit",
        )
        cleanup_temporary(paths)
        remove_journal(paths)
        verify_immutable_inputs(immutable_inputs, "after committed recovery")
        return

    restore_one(
        paths.live_carrier,
        paths.carrier_backup,
        paths.carrier_discard,
        record["old_carrier_sha256"],
        paths.live_paths,
    )
    restore_one(
        paths.live_framework,
        paths.framework_backup,
        paths.framework_discard,
        record["old_framework_sha256"],
        paths.live_paths,
    )
    cleanup_temporary(paths)
    require_sha256(
        paths.core_archive,
        record["core_sha256"],
        "frozen official core after recovery",
    )
    require_sha256(
        paths.self_carrier,
        record["preserve_sha256"],
        "frozen self carrier after recovery",
    )
    remove_journal(paths)
    verify_immutable_inputs(immutable_inputs, "after rollback recovery")


def verify_fixed_inputs(
    args: argparse.Namespace, paths: Paths
) -> tuple[Path, Path, Path, tuple[tuple[str, Path, str], ...]]:
    task_root = require_task_root(args.task_root, paths.root)
    candidate_carrier = require_under_task_root(
        args.candidate_carrier, task_root, "candidate carrier"
    )
    candidate_framework = require_under_task_root(
        args.candidate_framework, task_root, "candidate framework"
    )
    preserve = require_canonical_existing(args.preserve_path, "preserve path")
    if preserve != paths.self_carrier.resolve(strict=True):
        raise PromotionError(
            f"preserve path must be the fixed self carrier: {paths.self_carrier}"
        )
    if candidate_carrier in paths.live_paths or candidate_framework in paths.live_paths:
        raise PromotionError("candidate path aliases a live product path")
    require_sha256(
        paths.live_carrier,
        args.expected_old_carrier_sha256,
        "old official carrier",
    )
    require_sha256(
        paths.live_framework,
        args.expected_old_framework_sha256,
        "old official framework",
    )
    require_sha256(preserve, args.expected_preserve_sha256, "frozen self carrier")
    require_sha256(
        paths.core_archive,
        args.expected_core_sha256,
        "frozen official core",
    )
    immutable_inputs = immutable_inputs_from_args(args)
    verify_immutable_inputs(immutable_inputs, "at transaction entry")
    return task_root, candidate_carrier, candidate_framework, immutable_inputs


def promote(args: argparse.Namespace, paths: Paths) -> None:
    (
        task_root,
        candidate_carrier,
        candidate_framework,
        immutable_inputs,
    ) = verify_fixed_inputs(args, paths)
    require_sha256(
        candidate_carrier,
        args.expected_candidate_carrier_sha256,
        "candidate official carrier",
    )
    injected_failure("candidate_carrier_validated")
    require_sha256(
        candidate_framework,
        args.expected_candidate_framework_sha256,
        "candidate official framework",
    )
    injected_failure("candidate_framework_validated")

    record: dict[str, Any] = {
        "schema": SCHEMA,
        "phase": "preparing",
        "product_root": str(paths.root),
        "task_root": str(task_root),
        "old_carrier_sha256": args.expected_old_carrier_sha256,
        "old_framework_sha256": args.expected_old_framework_sha256,
        "candidate_carrier_sha256": args.expected_candidate_carrier_sha256,
        "candidate_framework_sha256": args.expected_candidate_framework_sha256,
        "preserve_sha256": args.expected_preserve_sha256,
        "core_sha256": args.expected_core_sha256,
        "immutable_inputs": immutable_input_record(immutable_inputs),
    }
    try:
        write_journal(paths.journal, record)
        injected_crash("journal_persisted")

        copy_candidate(candidate_carrier, paths.carrier_stage, paths.live_paths)
        injected_crash("carrier_stage_fsynced")
        copy_candidate(candidate_framework, paths.framework_stage, paths.live_paths)
        injected_crash("framework_stage_fsynced")
        require_sha256(
            paths.carrier_stage,
            args.expected_candidate_carrier_sha256,
            "staged official carrier",
        )
        require_sha256(
            paths.framework_stage,
            args.expected_candidate_framework_sha256,
            "staged official framework",
        )
        injected_failure("staging_complete")
        set_phase(paths, record, "staging_complete")

        require_sha256(
            paths.live_carrier,
            args.expected_old_carrier_sha256,
            "old official carrier immediately before promotion",
        )
        require_sha256(
            paths.live_framework,
            args.expected_old_framework_sha256,
            "old official framework immediately before promotion",
        )
        require_sha256(
            paths.self_carrier,
            args.expected_preserve_sha256,
            "frozen self carrier immediately before promotion",
        )
        require_sha256(
            paths.core_archive,
            args.expected_core_sha256,
            "frozen official core immediately before promotion",
        )
        injected_immutable_drift("before_first_live_rename", immutable_inputs)
        verify_immutable_inputs(immutable_inputs, "immediately before promotion")

        move_live_to_backup(paths.live_carrier, paths.carrier_backup)
        require_sha256(
            paths.carrier_backup,
            args.expected_old_carrier_sha256,
            "old official carrier backup",
        )
        install_stage(paths.carrier_stage, paths.live_carrier)
        set_phase(paths, record, "live_carrier_renamed")
        injected_failure("live_carrier_renamed")
        injected_crash("live_carrier_renamed")

        move_live_to_backup(paths.live_framework, paths.framework_backup)
        require_sha256(
            paths.framework_backup,
            args.expected_old_framework_sha256,
            "old official framework backup",
        )
        install_stage(paths.framework_stage, paths.live_framework)
        set_phase(paths, record, "live_framework_renamed")
        injected_failure("live_framework_renamed")
        injected_crash("live_framework_renamed")

        require_sha256(
            paths.live_carrier,
            args.expected_candidate_carrier_sha256,
            "promoted official carrier",
        )
        require_sha256(
            paths.live_framework,
            args.expected_candidate_framework_sha256,
            "promoted official framework",
        )
        require_sha256(
            paths.self_carrier,
            args.expected_preserve_sha256,
            "frozen self carrier before commit",
        )
        require_sha256(
            paths.core_archive,
            args.expected_core_sha256,
            "frozen official core before commit",
        )
        verify_immutable_inputs(immutable_inputs, "before commit")
        injected_failure("final_pair_verified")
        set_phase(paths, record, "final_verified_before_commit")
        injected_crash("final_verified_before_commit")

        set_phase(paths, record, "committed")
        cleanup_temporary(paths)
        require_sha256(
            paths.self_carrier,
            args.expected_preserve_sha256,
            "frozen self carrier after commit",
        )
        require_sha256(
            paths.core_archive,
            args.expected_core_sha256,
            "frozen official core after commit",
        )
        verify_immutable_inputs(immutable_inputs, "after commit")
        remove_journal(paths)
    except BaseException:
        if paths.journal.exists():
            recover(paths)
        else:
            cleanup_temporary(paths)
        raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--recover-only", action="store_true")
    result.add_argument("--assert-ready", action="store_true")
    result.add_argument("--sha256-path")
    result.add_argument("--task-root")
    result.add_argument("--candidate-carrier")
    result.add_argument("--candidate-framework")
    result.add_argument("--expected-old-carrier-sha256")
    result.add_argument("--expected-old-framework-sha256")
    result.add_argument("--expected-candidate-carrier-sha256")
    result.add_argument("--expected-candidate-framework-sha256")
    result.add_argument("--preserve-path")
    result.add_argument("--expected-preserve-sha256")
    result.add_argument("--expected-core-sha256")
    result.add_argument("--expected-ready-carrier-sha256")
    result.add_argument("--expected-ready-framework-sha256")
    result.add_argument("--dawn-archive")
    result.add_argument("--expected-dawn-sha256")
    result.add_argument("--ceres-archive")
    result.add_argument("--expected-ceres-sha256")
    result.add_argument("--glog-archive")
    result.add_argument("--expected-glog-sha256")
    result.add_argument("--sqlite-tbd")
    result.add_argument("--expected-sqlite-tbd-sha256")
    return result


def require_promotion_arguments(args: argparse.Namespace) -> None:
    missing = [
        name
        for name in (
            "task_root",
            "candidate_carrier",
            "candidate_framework",
            "expected_old_carrier_sha256",
            "expected_old_framework_sha256",
            "expected_candidate_carrier_sha256",
            "expected_candidate_framework_sha256",
            "preserve_path",
            "expected_preserve_sha256",
            "expected_core_sha256",
            "dawn_archive",
            "expected_dawn_sha256",
            "ceres_archive",
            "expected_ceres_sha256",
            "glog_archive",
            "expected_glog_sha256",
            "sqlite_tbd",
            "expected_sqlite_tbd_sha256",
        )
        if not getattr(args, name)
    ]
    if missing:
        raise PromotionError("missing promotion arguments: " + ", ".join(missing))


def assert_ready(args: argparse.Namespace, paths: Paths) -> None:
    missing = [
        name
        for name in (
            "expected_ready_carrier_sha256",
            "expected_ready_framework_sha256",
            "preserve_path",
            "expected_preserve_sha256",
            "expected_core_sha256",
            "dawn_archive",
            "expected_dawn_sha256",
            "ceres_archive",
            "expected_ceres_sha256",
            "glog_archive",
            "expected_glog_sha256",
            "sqlite_tbd",
            "expected_sqlite_tbd_sha256",
        )
        if not getattr(args, name)
    ]
    if missing:
        raise PromotionError("missing readiness arguments: " + ", ".join(missing))
    if paths.journal.exists() or any(
        path.exists() or path.is_symlink() for path in paths.temporary_paths
    ):
        raise PromotionError("official pair is not ready: transaction state is active")
    preserve = require_canonical_existing(args.preserve_path, "preserve path")
    if preserve != paths.self_carrier.resolve(strict=True):
        raise PromotionError("readiness preserve path is not the fixed self carrier")
    require_sha256(
        paths.live_carrier,
        args.expected_ready_carrier_sha256,
        "ready official carrier",
    )
    require_sha256(
        paths.live_framework,
        args.expected_ready_framework_sha256,
        "ready official framework",
    )
    require_sha256(
        paths.self_carrier,
        args.expected_preserve_sha256,
        "ready frozen self carrier",
    )
    require_sha256(
        paths.core_archive,
        args.expected_core_sha256,
        "ready frozen official core",
    )
    verify_immutable_inputs(
        immutable_inputs_from_args(args), "at committed-pair readiness"
    )


def main() -> int:
    args = parser().parse_args()
    if args.sha256_path:
        if args.recover_only or args.assert_ready:
            raise PromotionError("--sha256-path is exclusive with transaction modes")
        print(sha256_path(Path(args.sha256_path).resolve()))
        return 0
    script = Path(__file__)
    root = resolve_product_root(script)
    paths = Paths(root)
    paths.journal.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(paths.lock, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.recover_only and args.assert_ready:
            raise PromotionError("--recover-only and --assert-ready are exclusive")
        if args.recover_only:
            recover(paths)
        elif args.assert_ready:
            assert_ready(args, paths)
        else:
            require_promotion_arguments(args)
            if paths.journal.exists():
                raise PromotionError(
                    "active journal requires an explicit --recover-only invocation"
                )
            promote(args, paths)
        return 0
    finally:
        os.close(lock_fd)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PromotionError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
