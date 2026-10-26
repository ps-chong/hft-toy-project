"""Regenerates smoke.onnx, the ONNX Runtime smoke-test model: y = 2x + 1 on a
float32[4] tensor (Mul then Add, opset 13, IR version 8).

    python3 -m venv /tmp/onnx && /tmp/onnx/bin/pip install onnx==1.16.1
    /tmp/onnx/bin/python make_model.py smoke.onnx

ONNX serialization is deterministic, so the same onnx version reproduces the
checked-in file byte for byte.
"""

from __future__ import annotations

import sys

import onnx
from onnx import TensorProto, helper


def build() -> onnx.ModelProto:
    x = helper.make_tensor_value_info("x", TensorProto.FLOAT, [4])
    y = helper.make_tensor_value_info("y", TensorProto.FLOAT, [4])
    two = helper.make_tensor("two", TensorProto.FLOAT, [], [2.0])
    one = helper.make_tensor("one", TensorProto.FLOAT, [], [1.0])
    nodes = [
        helper.make_node("Mul", ["x", "two"], ["scaled"]),
        helper.make_node("Add", ["scaled", "one"], ["y"]),
    ]
    graph = helper.make_graph(nodes, "hft_smoke", [x], [y], initializer=[two, one])
    model = helper.make_model(
        graph,
        producer_name="hft-onnx-smoke",
        opset_imports=[helper.make_opsetid("", 13)],
    )
    # Readable by every ONNX Runtime release since 1.10.
    model.ir_version = 8
    onnx.checker.check_model(model)
    return model


if __name__ == "__main__":
    onnx.save(build(), sys.argv[1] if len(sys.argv) > 1 else "smoke.onnx")
