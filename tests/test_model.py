import ctypes
from pathlib import Path

import pytest

from aibrain_rkllm.abi import RKLLMParam
from aibrain_rkllm.model import MAX_CONTEXT_LENGTH, initialize_model


class FakeFunction:
    def __init__(self, implementation):
        self.implementation = implementation
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        return self.implementation(*args)


class FakeLibrary:
    def __init__(self, init_result: int = 0, set_handle: bool = True):
        self.destroy_calls: list[int] = []
        self.init_parameters: RKLLMParam | None = None

        self.rkllm_createDefaultParam = FakeFunction(RKLLMParam)
        self.rkllm_destroy = FakeFunction(self._destroy)
        self.rkllm_init = FakeFunction(
            lambda handle, parameters, callback: self._initialize(
                handle, parameters, callback, init_result, set_handle
            )
        )

    def _initialize(self, handle, parameters, _callback, result, set_handle):
        self.init_parameters = parameters._obj
        if result == 0 and set_handle:
            handle._obj.value = 0x1234
        return result

    def _destroy(self, handle):
        self.destroy_calls.append(handle.value)
        return 0


def test_initialize_model_uses_fixed_context_and_releases_once(tmp_path: Path) -> None:
    model_path = tmp_path / "model.rkllm"
    model_path.write_bytes(b"model")
    library = FakeLibrary()

    model = initialize_model(library, model_path)

    assert library.init_parameters is not None
    assert library.init_parameters.model_path == bytes(model_path)
    assert library.init_parameters.max_context_len == MAX_CONTEXT_LENGTH
    assert library.init_parameters.max_new_tokens == 512
    assert model.close() is True
    assert model.close() is False
    assert library.destroy_calls == [0x1234]


def test_initialize_model_rejects_failed_native_initialization(tmp_path: Path) -> None:
    model_path = tmp_path / "model.rkllm"
    model_path.write_bytes(b"model")

    with pytest.raises(RuntimeError, match="rc=7"):
        initialize_model(FakeLibrary(init_result=7), model_path)


def test_initialize_model_rejects_missing_handle_on_success(tmp_path: Path) -> None:
    model_path = tmp_path / "model.rkllm"
    model_path.write_bytes(b"model")

    with pytest.raises(RuntimeError, match="without a handle"):
        initialize_model(FakeLibrary(set_handle=False), model_path)


def test_initialize_model_rejects_unapproved_context(tmp_path: Path) -> None:
    model_path = tmp_path / "model.rkllm"
    model_path.write_bytes(b"model")

    with pytest.raises(ValueError, match="context length"):
        initialize_model(FakeLibrary(), model_path, max_context_length=512)
