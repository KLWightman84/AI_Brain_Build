#!/usr/bin/env python3
"""Convert the approved Qwen3.5 4B model to a RK3588 RKLLM artifact.

This wrapper intentionally fixes the clean-rebuild conversion contract:
W8A8 quantization, the RK3588 target, three NPU cores, and 4096 context tokens.
It requires explicit local paths and never overwrites an existing output artifact.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Callable

TARGET_PLATFORM = "rk3588"
NUM_NPU_CORES = 3
QUANTIZED_DTYPE = "w8a8"
QUANTIZED_ALGORITHM = "normal"
MAX_CONTEXT = 4096


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--calibration-inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cpu")
    return parser.parse_args()


def require_paths(model_dir: Path, calibration_inputs: Path, output: Path) -> None:
    if not model_dir.is_dir():
        raise ValueError(f"model directory does not exist: {model_dir}")
    if not calibration_inputs.is_file():
        raise ValueError(f"calibration inputs do not exist: {calibration_inputs}")
    if output.exists():
        raise ValueError(f"refusing to overwrite existing output: {output}")


def check_result(stage: str, result: int) -> None:
    if result != 0:
        raise RuntimeError(f"RKLLM {stage} failed with status {result}")


def convert(
    model_dir: Path,
    calibration_inputs: Path,
    output: Path,
    device: str,
    rkllm_factory: Callable[[], object],
) -> None:
    """Run the supported RKLLM conversion flow using the fixed project contract."""
    require_paths(model_dir, calibration_inputs, output)
    output.parent.mkdir(parents=True, exist_ok=True)

    llm = rkllm_factory()
    print(f"Loading model from {model_dir}")
    check_result("model load", llm.load_huggingface(model=str(model_dir), device=device))

    print("Building W8A8 RK3588 artifact (3 NPU cores, context 4096)")
    check_result(
        "build",
        llm.build(
            do_quantization=True,
            optimization_level=1,
            quantized_dtype=QUANTIZED_DTYPE,
            quantized_algorithm=QUANTIZED_ALGORITHM,
            target_platform=TARGET_PLATFORM,
            num_npu_core=NUM_NPU_CORES,
            extra_qparams=None,
            dataset=str(calibration_inputs),
            hybrid_rate=0,
            max_context=MAX_CONTEXT,
        ),
    )

    print(f"Exporting RKLLM artifact to {output}")
    check_result("export", llm.export_rkllm(str(output)))


def main() -> int:
    args = parse_args()
    try:
        from rkllm.api import RKLLM

        convert(
            args.model_dir,
            args.calibration_inputs,
            args.output,
            args.device,
            RKLLM,
        )
    except (ImportError, OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}")
        return 1

    print("RKLLM conversion completed successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
