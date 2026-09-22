#!/usr/bin/env python3
"""Compile and interpret the OpenMVS-PCG GLSL vector contract.

This is deliberately not reported as GPU execution. It compiles the real GLSL
include to SPIR-V, validates the module, disassembles that module, and executes
the small deterministic opcode subset emitted by glslang for the test entry
point. Unsupported instructions fail closed.
"""

from __future__ import annotations

import hashlib
import json
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


MASK32 = 0xFFFFFFFF
EXPECTED = [
    1234,
    2254131583,
    1819980427,
    8041099,
    0x3EF56516,
    4294957280,
    187688824,
    808217463,
    2084420317,
    1970291471,
    7357199,
    0x3EE0861E,
    250498,
    3691548399,
    1518259290,
    0x3EFD98B4,
]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


@dataclass
class Cell:
    value: Any = None


@dataclass(frozen=True)
class Pointer:
    cell: Cell
    path: tuple[int, ...] = ()

    def derive(self, indices: list[int]) -> "Pointer":
        return Pointer(self.cell, self.path + tuple(indices))

    def load(self) -> Any:
        value = self.cell.value
        for index in self.path:
            value = value[index]
        return value

    def store(self, value: Any) -> None:
        if not self.path:
            self.cell.value = value
            return
        target = self.cell.value
        for index in self.path[:-1]:
            target = target[index]
        target[self.path[-1]] = value


@dataclass(frozen=True)
class Instruction:
    result: str | None
    opcode: str
    operands: tuple[str, ...]


@dataclass
class Function:
    identifier: str
    parameters: list[str] = field(default_factory=list)
    instructions: list[Instruction] = field(default_factory=list)


class SpirvInterpreter:
    def __init__(self, assembly: str) -> None:
        self.types: dict[str, tuple[Any, ...]] = {}
        self.constants: dict[str, Any] = {}
        self.globals: dict[str, Pointer] = {}
        self.functions: dict[str, Function] = {}
        self.entry_point: str | None = None
        self._parse(assembly)

    @staticmethod
    def _tokenize(line: str) -> list[str]:
        lexer = shlex.shlex(line, posix=True)
        lexer.whitespace_split = True
        lexer.commenters = ";"
        return list(lexer)

    def _parse(self, assembly: str) -> None:
        current: Function | None = None
        for line in assembly.splitlines():
            tokens = self._tokenize(line)
            if not tokens:
                continue
            result = None
            if len(tokens) >= 3 and tokens[1] == "=":
                result = tokens[0]
                opcode = tokens[2]
                operands = tuple(tokens[3:])
            else:
                opcode = tokens[0]
                operands = tuple(tokens[1:])
            instruction = Instruction(result, opcode, operands)

            if opcode == "OpEntryPoint":
                self.entry_point = operands[1]
            elif opcode == "OpTypeInt":
                assert result is not None
                self.types[result] = ("int", int(operands[0]), int(operands[1]))
            elif opcode == "OpTypeFloat":
                assert result is not None
                self.types[result] = ("float", int(operands[0]))
            elif opcode == "OpTypeVector":
                assert result is not None
                self.types[result] = ("vector", operands[0], int(operands[1]))
            elif opcode == "OpConstant":
                assert result is not None
                value_type = self.types[operands[0]]
                if value_type[0] == "float":
                    self.constants[result] = f32(float(operands[1]))
                else:
                    self.constants[result] = int(operands[1], 0)
            elif opcode == "OpConstantComposite":
                assert result is not None
                self.constants[result] = tuple(
                    self.constants[item] for item in operands[1:]
                )
            elif opcode == "OpFunction":
                assert result is not None and current is None
                current = Function(result)
                self.functions[result] = current
            elif opcode == "OpFunctionParameter":
                assert result is not None and current is not None
                current.parameters.append(result)
            elif opcode == "OpFunctionEnd":
                if current is None:
                    raise RuntimeError("OpFunctionEnd outside a function")
                current = None
            elif current is not None:
                current.instructions.append(instruction)
            elif opcode == "OpVariable":
                assert result is not None
                storage_class = operands[1]
                if storage_class != "StorageBuffer":
                    raise RuntimeError(
                        f"unsupported global storage class: {storage_class}"
                    )
                self.globals[result] = Pointer(Cell([[0] * 64]))

        if self.entry_point is None or self.entry_point not in self.functions:
            raise RuntimeError("SPIR-V module has no executable entry point")

    def _resolve(self, token: str, frame: dict[str, Any]) -> Any:
        if token in frame:
            return frame[token]
        if token in self.constants:
            return self.constants[token]
        if token in self.globals:
            return self.globals[token]
        raise RuntimeError(f"unresolved SPIR-V identifier: {token}")

    def _execute_function(self, identifier: str, arguments: list[Any]) -> Any:
        function = self.functions[identifier]
        if len(arguments) != len(function.parameters):
            raise RuntimeError(f"argument count mismatch for {identifier}")
        frame = dict(zip(function.parameters, arguments, strict=True))

        for instruction in function.instructions:
            result = instruction.result
            opcode = instruction.opcode
            operands = instruction.operands

            if opcode == "OpLabel":
                continue
            if opcode == "OpVariable":
                assert result is not None
                frame[result] = Pointer(Cell())
                continue
            if opcode == "OpStore":
                pointer = self._resolve(operands[0], frame)
                if not isinstance(pointer, Pointer):
                    raise RuntimeError("OpStore target is not a pointer")
                pointer.store(self._resolve(operands[1], frame))
                continue
            if opcode == "OpReturn":
                return None
            if opcode == "OpReturnValue":
                return self._resolve(operands[0], frame)

            if result is None:
                raise RuntimeError(f"unsupported result-less opcode: {opcode}")

            if opcode == "OpLoad":
                pointer = self._resolve(operands[1], frame)
                if not isinstance(pointer, Pointer):
                    raise RuntimeError("OpLoad source is not a pointer")
                value = pointer.load()
            elif opcode == "OpAccessChain":
                pointer = self._resolve(operands[1], frame)
                if not isinstance(pointer, Pointer):
                    raise RuntimeError("OpAccessChain base is not a pointer")
                indices = [
                    int(self._resolve(item, frame)) for item in operands[2:]
                ]
                value = pointer.derive(indices)
            elif opcode == "OpFunctionCall":
                function_id = operands[1]
                call_arguments = [
                    self._resolve(item, frame) for item in operands[2:]
                ]
                value = self._execute_function(function_id, call_arguments)
            elif opcode in {"OpIAdd", "OpIMul"}:
                lhs = int(self._resolve(operands[1], frame))
                rhs = int(self._resolve(operands[2], frame))
                value = (lhs + rhs) if opcode == "OpIAdd" else (lhs * rhs)
                value &= MASK32
            elif opcode == "OpShiftRightLogical":
                lhs = int(self._resolve(operands[1], frame)) & MASK32
                rhs = int(self._resolve(operands[2], frame))
                value = lhs >> rhs
            elif opcode in {"OpBitwiseAnd", "OpBitwiseXor"}:
                lhs = int(self._resolve(operands[1], frame))
                rhs = int(self._resolve(operands[2], frame))
                value = lhs & rhs if opcode == "OpBitwiseAnd" else lhs ^ rhs
                value &= MASK32
            elif opcode == "OpConvertUToF":
                integer = int(self._resolve(operands[1], frame)) & MASK32
                value = f32(float(integer))
            elif opcode == "OpFDiv":
                lhs = f32(float(self._resolve(operands[1], frame)))
                rhs = f32(float(self._resolve(operands[2], frame)))
                value = f32(lhs / rhs)
            elif opcode == "OpBitcast":
                source = self._resolve(operands[1], frame)
                target_type = self.types[operands[0]]
                if target_type[0] == "int" and isinstance(source, float):
                    value = struct.unpack("<I", struct.pack("<f", source))[0]
                else:
                    raise RuntimeError("unsupported OpBitcast types")
            else:
                raise RuntimeError(f"unsupported SPIR-V opcode: {opcode}")
            frame[result] = value

        raise RuntimeError(f"function {identifier} did not return")

    def execute(self) -> list[int]:
        assert self.entry_point is not None
        self._execute_function(self.entry_point, [])
        storage_buffers = [pointer.load() for pointer in self.globals.values()]
        if len(storage_buffers) != 1:
            raise RuntimeError("expected exactly one storage buffer")
        return [int(value) & MASK32 for value in storage_buffers[0][0][:len(EXPECTED)]]


def run_checked(command: list[str], label: str) -> str:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        details = "\n".join(part for part in (result.stdout, result.stderr) if part)
        raise RuntimeError(f"{label} failed ({result.returncode})\n{details}")
    return result.stdout


def require_tool(name: str) -> str:
    executable = shutil.which(name)
    if executable is None:
        raise RuntimeError(f"required tool unavailable: {name}")
    return executable


def verify() -> dict[str, Any]:
    rng_root = Path(__file__).resolve().parent
    shader = rng_root / "openmvs_pcg_vector_contract.glsl"
    include = rng_root / "openmvs_pcg.glsl"
    glslang = require_tool("glslangValidator")
    spirv_val = require_tool("spirv-val")
    spirv_dis = require_tool("spirv-dis")

    with tempfile.TemporaryDirectory(prefix="openmvs_pcg_spirv_") as temporary:
        module = Path(temporary) / "vectors.spv"
        run_checked(
            [
                glslang,
                "-V",
                "--target-env",
                "vulkan1.1",
                "-S",
                "comp",
                "-Od",
                f"-I{rng_root}",
                "-o",
                str(module),
                str(shader),
            ],
            "compile vector shader",
        )
        run_checked(
            [spirv_val, "--target-env", "vulkan1.1", str(module)],
            "validate vector SPIR-V",
        )
        assembly = run_checked([spirv_dis, str(module)], "disassemble SPIR-V")
        observed = SpirvInterpreter(assembly).execute()
        if observed != EXPECTED:
            raise RuntimeError(
                f"SPIR-V vector mismatch: expected {EXPECTED}, got {observed}"
            )
        module_sha256 = sha256_file(module)

    return {
        "execution": "spirv-interpreter",
        "gpu_execution": False,
        "validated": True,
        "target_environment": "vulkan1.1",
        "vector_count": len(observed),
        "spirv_sha256": module_sha256,
        "glsl_include_sha256": sha256_file(include),
        "seed_0_0": observed[0],
        "next_state_0_0": observed[1],
        "raw_output_0_0": observed[2],
        "low24_0_0": observed[3],
        "uniform_float_bits_0_0": observed[4],
        "seed_wraparound": observed[5],
        "successive_state_2": observed[8],
        "successive_raw_2": observed[9],
    }


def main() -> int:
    try:
        report = verify()
    except (OSError, RuntimeError, ValueError, AssertionError) as error:
        print(f"OpenMVS PCG SPIR-V verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
