#!/usr/bin/env python3
"""Load and release an RKLLM model once without running inference."""

from __future__ import annotations

import argparse
from pathlib import Path

from aibrain_rkllm.model import initialize_model
from aibrain_rkllm.native import load_rkllm_library


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = None
    try:
        library = load_rkllm_library(args.library)
        model = initialize_model(library, args.model)
        print("RKLLM model initialization passed")
        return 0
    finally:
        if model is not None:
            model.close()
            print("RKLLM model released")


if __name__ == "__main__":
    raise SystemExit(main())
