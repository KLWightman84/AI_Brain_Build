#!/usr/bin/env python3
"""Reinitialize the RKLLM artifact repeatedly with explicit single-owner release."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from aibrain_rkllm.inference import PromptResponseCollector, run_prompt
from aibrain_rkllm.model import initialize_model
from aibrain_rkllm.native import load_rkllm_library
from aibrain_rkllm.restart import ready_response_is_valid

PROMPT = "Reply with only the word READY."
DEFAULT_CYCLES = 3


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--cycles", type=int, default=DEFAULT_CYCLES)
    return parser.parse_args()


def write_report(path: Path, report: dict[str, object]) -> None:
    if path.exists():
        raise FileExistsError(f"refusing to overwrite report: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def main() -> int:
    args = parse_args()
    if args.cycles < 2:
        raise ValueError("cycles must be at least 2 for a restart gate")

    library = load_rkllm_library(args.library)
    started = time.monotonic()
    responses: list[str] = []
    released_cycles: list[int] = []

    for cycle in range(1, args.cycles + 1):
        collector = PromptResponseCollector()
        model = None
        try:
            model = initialize_model(library, args.model, result_handler=collector)
            run_prompt(library, model, PROMPT, max_new_tokens=8)
            if not ready_response_is_valid(collector):
                raise RuntimeError(
                    f"cycle {cycle}: expected completed READY response; "
                    f"got {collector.text.strip()!r}"
                )
            responses.append(collector.text.strip())
        finally:
            if model is not None:
                if not model.close():
                    raise RuntimeError(f"cycle {cycle}: native handle was already released")
                released_cycles.append(cycle)

        print(f"RKLLM restart cycle {cycle}/{args.cycles} passed")

    report = {
        "artifact": args.model.name,
        "cycle_count": args.cycles,
        "released_cycles": released_cycles,
        "responses": responses,
        "total_duration_seconds": round(time.monotonic() - started, 3),
    }
    write_report(args.report, report)
    print(f"RKLLM reinitialization test passed; report: {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
