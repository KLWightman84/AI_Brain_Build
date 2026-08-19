import ctypes
from types import SimpleNamespace

import pytest

from aibrain_rkllm.inference import PromptResponseCollector, run_prompt
from aibrain_rkllm.protocol import RKLLMResult, RKLLM_RUN_ERROR, RKLLM_RUN_FINISH, RKLLM_RUN_NORMAL


class FakeFunction:
    def __init__(self, implementation):
        self.implementation = implementation
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        return self.implementation(*args)


class FakeLibrary:
    def __init__(self):
        self.input = None
        self.parameters = None
        self.rkllm_run = FakeFunction(self._run)

    def _run(self, _handle, rkllm_input, parameters, _userdata):
        self.input = rkllm_input._obj
        self.parameters = parameters._obj
        return 0


def test_collector_records_text_finish_and_error() -> None:
    collector = PromptResponseCollector()
    result = RKLLMResult(text=b"ready")

    assert collector(ctypes.pointer(result), RKLLM_RUN_NORMAL) == 0
    assert collector(None, RKLLM_RUN_FINISH) == 0
    assert collector.text == "ready"
    assert collector.finished is True
    assert collector.errored is False

    assert collector(None, RKLLM_RUN_ERROR) == 0
    assert collector.errored is True


def test_run_prompt_uses_stateless_user_generation() -> None:
    library = FakeLibrary()
    model = SimpleNamespace(handle=ctypes.c_void_p(0x1234))

    assert run_prompt(library, model, "Reply READY", max_new_tokens=16) == 0
    assert library.input.role == b"user"
    assert library.input.enable_thinking is False
    assert library.input.input_type == 0
    assert library.input.prompt_input == b"Reply READY"
    assert library.parameters.mode == 0
    assert library.parameters.keep_history == 0
    assert library.parameters.max_new_tokens == 16


@pytest.mark.parametrize("prompt", ["", "   "])
def test_run_prompt_rejects_empty_prompt(prompt: str) -> None:
    with pytest.raises(ValueError, match="must not be empty"):
        run_prompt(FakeLibrary(), SimpleNamespace(handle=ctypes.c_void_p(1)), prompt)
