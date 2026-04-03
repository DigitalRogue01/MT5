#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path
import onnx
from onnx import TensorProto, checker, helper

def make_model() -> onnx.ModelProto:
    tvi = helper.make_tensor_value_info
    inputs = [
        tvi("high", TensorProto.FLOAT, ["N"]),
        tvi("low", TensorProto.FLOAT, ["N"]),
        tvi("close", TensorProto.FLOAT, ["N"]),
    ]
    outputs = [
        tvi("h1", TensorProto.FLOAT, ["N"]),
        tvi("h2", TensorProto.FLOAT, ["N"]),
        tvi("h3", TensorProto.FLOAT, ["N"]),
        tvi("h4", TensorProto.FLOAT, ["N"]),
        tvi("l1", TensorProto.FLOAT, ["N"]),
        tvi("l2", TensorProto.FLOAT, ["N"]),
        tvi("l3", TensorProto.FLOAT, ["N"]),
        tvi("l4", TensorProto.FLOAT, ["N"]),
    ]
    init = [
        helper.make_tensor("k_1_1", TensorProto.FLOAT, [1], [1.1]),
        helper.make_tensor("k_inv_12", TensorProto.FLOAT, [1], [1.0/12.0]),
        helper.make_tensor("k_inv_6", TensorProto.FLOAT, [1], [1.0/6.0]),
        helper.make_tensor("k_inv_4", TensorProto.FLOAT, [1], [1.0/4.0]),
        helper.make_tensor("k_inv_2", TensorProto.FLOAT, [1], [1.0/2.0]),
    ]
    nodes = [
        helper.make_node("Sub", ["high", "low"], ["range"]),
        helper.make_node("Mul", ["range", "k_1_1"], ["scaled"]),
        helper.make_node("Mul", ["scaled", "k_inv_12"], ["off_12"]),
        helper.make_node("Mul", ["scaled", "k_inv_6"], ["off_6"]),
        helper.make_node("Mul", ["scaled", "k_inv_4"], ["off_4"]),
        helper.make_node("Mul", ["scaled", "k_inv_2"], ["off_2"]),
        helper.make_node("Add", ["close", "off_12"], ["h1"]),
        helper.make_node("Add", ["close", "off_6"], ["h2"]),
        helper.make_node("Add", ["close", "off_4"], ["h3"]),
        helper.make_node("Add", ["close", "off_2"], ["h4"]),
        helper.make_node("Sub", ["close", "off_12"], ["l1"]),
        helper.make_node("Sub", ["close", "off_6"], ["l2"]),
        helper.make_node("Sub", ["close", "off_4"], ["l3"]),
        helper.make_node("Sub", ["close", "off_2"], ["l4"]),
    ]
    graph = helper.make_graph(nodes, "camarilla_levels_graph", inputs, outputs, initializer=init)
    model = helper.make_model(graph, producer_name="mt5-camarilla-generator", opset_imports=[helper.make_operatorsetid("", 13)])
    checker.check_model(model)
    return model

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--output", type=Path, default=Path("Models/camarilla_levels.onnx"))
    args = p.parse_args()
    m = make_model()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(m, args.output)
    print(f"Wrote model to {args.output}")

if __name__ == "__main__":
    main()
