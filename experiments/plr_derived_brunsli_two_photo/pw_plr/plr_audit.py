"""Static evidence for gaps in the pinned public PLR codec entry point."""

from __future__ import annotations

import ast


def _self_attributes(node: ast.AST, *, context: type[ast.expr_context]) -> set[str]:
    attributes: set[str] = set()
    for child in ast.walk(node):
        if (
            isinstance(child, ast.Attribute)
            and isinstance(child.value, ast.Name)
            and child.value.id == "self"
            and isinstance(child.ctx, context)
        ):
            attributes.add(child.attr)
    return attributes


def audit_class_source(source: str, class_name: str) -> dict[str, object]:
    """Report codec methods that read members absent from the constructor."""
    module = ast.parse(source)
    class_node = next(
        (
            node
            for node in module.body
            if isinstance(node, ast.ClassDef) and node.name == class_name
        ),
        None,
    )
    if class_node is None:
        raise ValueError(f"class not found: {class_name}")
    methods = {
        node.name: node
        for node in class_node.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    constructor = methods.get("__init__")
    if constructor is None:
        raise ValueError(f"constructor not found: {class_name}")
    constructor_attributes = _self_attributes(constructor, context=ast.Store)
    method_names = set(methods)

    def undefined(method_name: str) -> list[str]:
        method = methods.get(method_name)
        if method is None:
            return []
        reads = _self_attributes(method, context=ast.Load)
        return sorted(reads - constructor_attributes - method_names)

    forward = methods.get("forward")
    forward_reads = (
        _self_attributes(forward, context=ast.Load) if forward is not None else set()
    )
    return {
        "class_name": class_name,
        "constructor_attributes": sorted(constructor_attributes),
        "compress_undefined_attributes": undefined("compress"),
        "decompress_undefined_attributes": undefined("decompress"),
        "forward_reads_gaussian_cbcr": "Gaussian_CbCr" in forward_reads,
    }
