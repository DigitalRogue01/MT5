#!/usr/bin/env python3
from __future__ import annotations
import argparse, json
from pathlib import Path
import numpy as np
import onnx
from onnx.reference import ReferenceEvaluator

NAMES = ("h1","h2","h3","h4","l1","l2","l3","l4")

def run_once(model_path: Path, high: float, low: float, close: float):
    model = onnx.load(model_path)
    ref = ReferenceEvaluator(model)
    outs = ref.run(None, {
        "high": np.array([high], dtype=np.float32),
        "low": np.array([low], dtype=np.float32),
        "close": np.array([close], dtype=np.float32),
    })
    return {k: float(v[0]) for k, v in zip(NAMES, outs)}

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--high", type=float, required=True)
    p.add_argument("--low", type=float, required=True)
    p.add_argument("--close", type=float, required=True)
    p.add_argument("--model", type=Path, default=Path("Models/camarilla_levels.onnx"))
    a = p.parse_args()
    print(json.dumps(run_once(a.model, a.high, a.low, a.close), indent=2, sort_keys=True))

if __name__ == "__main__":
    main()
