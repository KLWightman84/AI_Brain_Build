#!/usr/bin/env python3
"""Run one short, stateless RKLLM prompt and release the model exactly once."""

from __future__ import annotations

import argparse
from pathlib import Path

from aibrain_rkllm.inference import PromptResponseCollector, run_prompt
from aibrain_rkllm.model import initialize_model
from aibrain_rkllm.native import load_rkllm_library

PROMPT = "Reply with only the word READY."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = None
    try:
        collector = PromptResponseCollector()
        library = load_rkllm_library(args.library)
        model = initialize_model(library, args.model, result_handler=collector)
        run_prompt(library, model, PROMPT, max_new_tokens=32)

        if collector.errored:
            raise RuntimeError("RKLLM callback reported an inference error")
        if not collector.finished:
            raise RuntimeError("RKLLM callback did not report completion")
        if not collector.text.strip():
            raise RuntimeError("RKLLM returned an empty response")

        print(f"RKLLM response: {collector.text.strip()}")
        print("RKLLM prompt inference passed")
        return 0
    finally:
        if model is not None:
            model.close()
            print("RKLLM model released")


if __name__ == "__main__":
    raise SystemExit(main())
