#!/usr/bin/env python3
"""Run 100 stateless RKLLM prompts and write a test-only memory report."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from aibrain_rkllm.inference import PromptResponseCollector, run_prompt
from aibrain_rkllm.model import initialize_model
from aibrain_rkllm.native import load_rkllm_library
from aibrain_rkllm.stability import current_rss_kib, tail_range_kib

REQUEST_COUNT = 100
PROMPT = "Reply with only the word READY."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def write_report(path: Path, report: dict[str, object]) -> None:
    if path.exists():
        raise FileExistsError(f"refusing to overwrite report: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def main() -> int:
    args = parse_args()
    model = None
    started = time.monotonic()
    try:
        collector = PromptResponseCollector()
        library = load_rkllm_library(args.library)
        model = initialize_model(library, args.model, result_handler=collector)
        rss_after_initialization_kib = current_rss_kib()
        rss_samples_kib: list[int] = []
        response_lengths: list[int] = []
        first_response = ""
        last_response = ""

        for request_number in range(1, REQUEST_COUNT + 1):
            collector.reset()
            run_prompt(library, model, PROMPT, max_new_tokens=8)
            response = collector.text.strip()
            if collector.errored:
                raise RuntimeError(f"request {request_number}: callback reported an error")
            if not collector.finished:
                raise RuntimeError(f"request {request_number}: callback did not report completion")
            if not response:
                raise RuntimeError(f"request {request_number}: empty response")

            if request_number == 1:
                first_response = response
            last_response = response
            response_lengths.append(len(response))
            rss_samples_kib.append(current_rss_kib())
            if request_number % 10 == 0:
                print(f"RKLLM request {request_number}/{REQUEST_COUNT} passed")

        report = {
            "artifact": args.model.name,
            "first_response": first_response,
            "last_response": last_response,
            "request_count": REQUEST_COUNT,
            "response_lengths": response_lengths,
            "rss_after_initialization_kib": rss_after_initialization_kib,
            "rss_final_kib": rss_samples_kib[-1],
            "rss_peak_kib": max(rss_samples_kib),
            "rss_tail_20_range_kib": tail_range_kib(rss_samples_kib, tail_count=20),
            "rss_samples_kib": rss_samples_kib,
            "total_duration_seconds": round(time.monotonic() - started, 3),
        }
        write_report(args.report, report)
        print(f"RKLLM 100/100 repeat test passed; report: {args.report}")
        return 0
    finally:
        if model is not None:
            model.close()
            print("RKLLM model released")


if __name__ == "__main__":
    raise SystemExit(main())
