#!/usr/bin/env python3
"""Exceed RKLLM context once, then prove a fresh short request recovers."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from aibrain_rkllm.inference import PromptResponseCollector, run_prompt
from aibrain_rkllm.model import initialize_model
from aibrain_rkllm.native import load_rkllm_library
from aibrain_rkllm.recovery import oversized_prompt

RECOVERY_PROMPT = "Reply with only the word READY."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--oversize-word-count", type=int, default=6000)
    return parser.parse_args()


def write_report(path: Path, report: dict[str, object]) -> None:
    if path.exists():
        raise FileExistsError(f"refusing to overwrite report: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def collector_outcome(collector: PromptResponseCollector) -> str:
    if collector.errored:
        return "callback_error"
    if not collector.finished:
        return "incomplete"
    if not collector.text.strip():
        return "empty_response"
    return "returned"


def main() -> int:
    args = parse_args()
    model = None
    started = time.monotonic()
    report: dict[str, object] = {
        "artifact": args.model.name,
        "oversize_word_count": args.oversize_word_count,
    }
    try:
        collector = PromptResponseCollector()
        library = load_rkllm_library(args.library)
        model = initialize_model(library, args.model, result_handler=collector)

        collector.reset()
        try:
            run_prompt(
                library,
                model,
                oversized_prompt(args.oversize_word_count),
                max_new_tokens=1,
            )
        except RuntimeError as error:
            report["oversize_outcome"] = "native_error"
            report["oversize_detail"] = str(error)
        else:
            report["oversize_outcome"] = collector_outcome(collector)
            report["oversize_response_length"] = len(collector.text.strip())

        collector.reset()
        run_prompt(library, model, RECOVERY_PROMPT, max_new_tokens=8)
        recovery_response = collector.text.strip()
        if collector.errored:
            raise RuntimeError("recovery request: callback reported an error")
        if not collector.finished:
            raise RuntimeError("recovery request: callback did not report completion")
        if recovery_response != "READY":
            raise RuntimeError(
                f"recovery request: expected READY, received {recovery_response!r}"
            )

        report["recovery_response"] = recovery_response
        report["recovery_completed"] = True
        report["total_duration_seconds"] = round(time.monotonic() - started, 3)
        write_report(args.report, report)
        print(
            "RKLLM oversized-context recovery passed; "
            f"oversize outcome: {report['oversize_outcome']}; report: {args.report}"
        )
        return 0
    finally:
        if model is not None:
            model.close()
            print("RKLLM model released")


if __name__ == "__main__":
    raise SystemExit(main())
