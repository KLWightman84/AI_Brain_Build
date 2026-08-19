"""Native RKLLM model initialization with explicit, single-owner cleanup."""

from __future__ import annotations

import ctypes
import os
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .abi import RKLLMParam, default_parameters
from .lifecycle import RKLLMHandleOwner

MAX_CONTEXT_LENGTH = 4096
DEFAULT_MAX_NEW_TOKENS = 512

ResultCallback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int)
TokenizerCallback = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_int32,
    ctypes.POINTER(ctypes.c_int32),
    ctypes.c_int32,
)
EmbedCallback = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_int32),
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_uint64,
)


class RKLLMCallback(ctypes.Structure):
    """ABI-compatible callback table from the v1.3.0 RKLLM header."""

    _fields_ = [
        ("result_callback", ResultCallback),
        ("result_userdata", ctypes.c_void_p),
        ("tokenizer_callback", TokenizerCallback),
        ("tokenizer_userdata", ctypes.c_void_p),
        ("embed_callback", EmbedCallback),
        ("embed_userdata", ctypes.c_void_p),
    ]


def bind_model_initialization(library: Any) -> None:
    library.rkllm_init.argtypes = [
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(RKLLMParam),
        ctypes.POINTER(RKLLMCallback),
    ]
    library.rkllm_init.restype = ctypes.c_int


def _discard_result(_: int, __: int, ___: int) -> int:
    """Safe no-op callback for the load-only acceptance gate."""
    return 0


@dataclass
class InitializedRKLLMModel:
    """A live model handle whose explicit owner releases it exactly once."""

    owner: RKLLMHandleOwner
    callback_table: RKLLMCallback
    result_callback: ResultCallback
    parameters: RKLLMParam

    @property
    def handle(self) -> Any:
        return self.owner._handle

    def close(self) -> bool:
        return self.owner.close()

    def __enter__(self) -> "InitializedRKLLMModel":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def initialize_model(
    library: Any,
    model_path: Path,
    *,
    max_context_length: int = MAX_CONTEXT_LENGTH,
    max_new_tokens: int = DEFAULT_MAX_NEW_TOKENS,
) -> InitializedRKLLMModel:
    """Load an RKLLM model without running inference.

    The caller must use the returned object as a context manager or call
    ``close()`` in a ``finally`` block. No signal handler may destroy the handle.
    """
    model_path = Path(model_path)
    if not model_path.is_file():
        raise FileNotFoundError(f"RKLLM model does not exist: {model_path}")
    if max_context_length != MAX_CONTEXT_LENGTH:
        raise ValueError(f"context length must remain {MAX_CONTEXT_LENGTH} until revalidated")
    if max_new_tokens <= 0:
        raise ValueError("max_new_tokens must be positive")

    parameters = default_parameters(library)
    parameters.model_path = os.fsencode(model_path)
    parameters.max_context_len = max_context_length
    parameters.max_new_tokens = max_new_tokens
    parameters.is_async = False

    result_callback = ResultCallback(_discard_result)
    callback_table = RKLLMCallback()
    callback_table.result_callback = result_callback
    callback_table.result_userdata = None
    callback_table.tokenizer_callback = TokenizerCallback()
    callback_table.tokenizer_userdata = None
    callback_table.embed_callback = EmbedCallback()
    callback_table.embed_userdata = None

    bind_model_initialization(library)
    handle = ctypes.c_void_p()
    result = library.rkllm_init(
        ctypes.byref(handle), ctypes.byref(parameters), ctypes.byref(callback_table)
    )
    if result != 0:
        raise RuntimeError(f"rkllm_init failed with rc={result}")
    if not handle.value:
        raise RuntimeError("rkllm_init returned success without a handle")

    return InitializedRKLLMModel(
        owner=RKLLMHandleOwner(handle, library.rkllm_destroy),
        callback_table=callback_table,
        result_callback=result_callback,
        parameters=parameters,
    )
