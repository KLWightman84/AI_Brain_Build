"""Synchronous text prompt inference for the first RKLLM acceptance gate."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass, field
from typing import Any

from .model import InitializedRKLLMModel
from .protocol import (
    RKLLMInferParam,
    RKLLMInput,
    RKLLMResult,
    RKLLM_INFER_GENERATE,
    RKLLM_INPUT_PROMPT,
    RKLLM_RUN_ERROR,
    RKLLM_RUN_FINISH,
    RKLLM_RUN_NORMAL,
)


@dataclass
class PromptResponseCollector:
    """Collect UTF-8 text emitted through one synchronous RKLLM callback."""

    pieces: list[str] = field(default_factory=list)
    finished: bool = False
    errored: bool = False

    def __call__(self, result: ctypes.POINTER(RKLLMResult), state: int) -> int:
        if state == RKLLM_RUN_NORMAL and result and result.contents.text:
            self.pieces.append(result.contents.text.decode("utf-8", errors="replace"))
        elif state == RKLLM_RUN_FINISH:
            self.finished = True
        elif state == RKLLM_RUN_ERROR:
            self.errored = True
        return 0

    @property
    def text(self) -> str:
        return "".join(self.pieces)


def bind_prompt_inference(library: Any) -> None:
    library.rkllm_run.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(RKLLMInput),
        ctypes.POINTER(RKLLMInferParam),
        ctypes.c_void_p,
    ]
    library.rkllm_run.restype = ctypes.c_int


def run_prompt(
    library: Any,
    model: InitializedRKLLMModel,
    prompt: str,
    *,
    max_new_tokens: int = 32,
) -> int:
    """Run one stateless user prompt and return the native status code."""
    if not prompt.strip():
        raise ValueError("prompt must not be empty")
    if max_new_tokens <= 0:
        raise ValueError("max_new_tokens must be positive")

    encoded_prompt = prompt.encode("utf-8")
    rkllm_input = RKLLMInput()
    rkllm_input.role = b"user"
    rkllm_input.enable_thinking = False
    rkllm_input.input_type = RKLLM_INPUT_PROMPT
    rkllm_input.prompt_input = encoded_prompt

    infer_parameters = RKLLMInferParam()
    infer_parameters.mode = RKLLM_INFER_GENERATE
    infer_parameters.keep_history = 0
    infer_parameters.max_new_tokens = max_new_tokens

    bind_prompt_inference(library)
    result = library.rkllm_run(
        model.handle,
        ctypes.byref(rkllm_input),
        ctypes.byref(infer_parameters),
        None,
    )
    if result != 0:
        raise RuntimeError(f"rkllm_run failed with rc={result}")
    return result
