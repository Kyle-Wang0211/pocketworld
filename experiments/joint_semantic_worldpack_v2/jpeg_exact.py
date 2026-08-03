from __future__ import annotations

import hashlib
import shlex
import shutil
import struct
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


MAGIC = b"PWCJPEG1"
VERSION = 1


class ExactJpegError(RuntimeError):
    pass


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


@dataclass(frozen=True)
class ExactJpegFrame:
    serialized: bytes
    source_bytes: int
    source_sha256: str
    tool_sha256: str
    restart_interval: int
    header: bytes
    component_shapes: tuple[tuple[int, int], ...]
    coefficient_counts: tuple[int, ...]
    coefficient_payload: bytes

    @property
    def coefficient_count(self) -> int:
        return sum(self.coefficient_counts)


def build_coefficient_tool(source: Path, output: Path) -> Path:
    source = Path(source)
    output = Path(output)
    compiler = shutil.which("clang++")
    pkg_config = shutil.which("pkg-config")
    if compiler is None or pkg_config is None:
        raise ExactJpegError("clang++ and pkg-config are required")
    if not source.is_file():
        raise ExactJpegError(f"coefficient tool source is missing: {source}")
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        cflags = shlex.split(
            subprocess.run(
                [pkg_config, "--cflags", "libjpeg"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        )
        libraries = shlex.split(
            subprocess.run(
                [pkg_config, "--libs", "libjpeg"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        )
        subprocess.run(
            [
                compiler,
                "-std=c++17",
                "-O2",
                "-Wall",
                "-Wextra",
                "-Werror",
                *cflags,
                str(source),
                *libraries,
                "-o",
                str(output),
            ],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as error:
        message = (error.stderr or error.stdout or b"").decode("utf-8", "replace")
        raise ExactJpegError(f"coefficient tool build failed: {message}") from error
    return output


def _run_tool(tool: Path, command: str, source: Path, output: Path) -> None:
    try:
        subprocess.run(
            [str(tool), command, str(source), str(output)],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as error:
        message = (error.stderr or error.stdout or b"").decode("utf-8", "replace")
        raise ExactJpegError(message.strip() or f"JPEG coefficient {command} failed") from error


def _parse_frame(
    serialized: bytes,
    *,
    source_bytes: int,
    source_sha256: str,
    tool_sha256: str,
) -> ExactJpegFrame:
    cursor = 0

    def take(size: int) -> bytes:
        nonlocal cursor
        if size < 0 or cursor + size > len(serialized):
            raise ExactJpegError("truncated exact JPEG frame")
        value = serialized[cursor : cursor + size]
        cursor += size
        return value

    if take(len(MAGIC)) != MAGIC:
        raise ExactJpegError("exact JPEG frame magic mismatch")
    version, restart_interval, component_count = struct.unpack("<III", take(12))
    if version != VERSION or component_count < 1 or component_count > 10:
        raise ExactJpegError("unsupported exact JPEG frame header")
    (header_size,) = struct.unpack("<Q", take(8))
    shapes: list[tuple[int, int]] = []
    counts: list[int] = []
    for _ in range(component_count):
        width_blocks, height_blocks, count = struct.unpack("<IIQ", take(16))
        if (
            width_blocks == 0
            or height_blocks == 0
            or count != width_blocks * height_blocks * 64
        ):
            raise ExactJpegError("invalid exact JPEG component dimensions")
        shapes.append((height_blocks, width_blocks))
        counts.append(count)
    header = take(header_size)
    coefficient_payload = take(sum(counts) * 2)
    if cursor != len(serialized):
        raise ExactJpegError("exact JPEG frame has trailing bytes")
    return ExactJpegFrame(
        serialized=serialized,
        source_bytes=source_bytes,
        source_sha256=source_sha256,
        tool_sha256=tool_sha256,
        restart_interval=restart_interval,
        header=header,
        component_shapes=tuple(shapes),
        coefficient_counts=tuple(counts),
        coefficient_payload=coefficient_payload,
    )


def extract_exact_jpeg(path: Path, tool: Path) -> ExactJpegFrame:
    return extract_exact_jpeg_bytes(Path(path).read_bytes(), tool)


def extract_exact_jpeg_bytes(source: bytes, tool: Path) -> ExactJpegFrame:
    tool = Path(tool)
    if not tool.is_file():
        raise ExactJpegError(f"coefficient tool is missing: {tool}")
    source_sha256 = _sha256_bytes(source)
    tool_sha256 = _sha256_bytes(tool.read_bytes())
    with tempfile.TemporaryDirectory(prefix="pw-jpeg-exact-", dir="/private/tmp") as scratch_text:
        scratch = Path(scratch_text)
        jpeg_path = scratch / "source.jpg"
        frame_path = scratch / "frame.pwcj"
        restored_path = scratch / "restored.jpg"
        jpeg_path.write_bytes(source)
        _run_tool(tool, "extract", jpeg_path, frame_path)
        serialized = frame_path.read_bytes()
        frame = _parse_frame(
            serialized,
            source_bytes=len(source),
            source_sha256=source_sha256,
            tool_sha256=tool_sha256,
        )
        _run_tool(tool, "restore", frame_path, restored_path)
        restored = restored_path.read_bytes()
        if restored != source or _sha256_bytes(restored) != source_sha256:
            raise ExactJpegError("coefficient frame did not restore the source JPEG exactly")
        return frame


def restore_exact_jpeg(frame: ExactJpegFrame, tool: Path) -> bytes:
    tool = Path(tool)
    if _sha256_bytes(tool.read_bytes()) != frame.tool_sha256:
        raise ExactJpegError("coefficient tool identity changed")
    parsed = _parse_frame(
        frame.serialized,
        source_bytes=frame.source_bytes,
        source_sha256=frame.source_sha256,
        tool_sha256=frame.tool_sha256,
    )
    with tempfile.TemporaryDirectory(prefix="pw-jpeg-restore-", dir="/private/tmp") as scratch_text:
        scratch = Path(scratch_text)
        frame_path = scratch / "frame.pwcj"
        restored_path = scratch / "restored.jpg"
        frame_path.write_bytes(parsed.serialized)
        _run_tool(tool, "restore", frame_path, restored_path)
        restored = restored_path.read_bytes()
    if len(restored) != frame.source_bytes or _sha256_bytes(restored) != frame.source_sha256:
        raise ExactJpegError("restored JPEG identity mismatch")
    return restored

