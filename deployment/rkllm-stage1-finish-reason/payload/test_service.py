import ctypes
from collections.abc import Iterable

from aibrain_rkllm.service import (
    MAX_CONTEXT_WORDS,
    MODEL_CONTEXT_TOKENS,
    QueuedResultCollector,
    RKLLMBackend,
    build_request_prompt,
    create_app,
)
from aibrain_rkllm.protocol import RKLLMResult, RKLLM_RUN_FINISH, RKLLM_RUN_NORMAL


class FakeBackend:
    model_id = "rkllm"
    finish_reason = "stop"

    def __init__(self) -> None:
        self.prompts: list[str] = []

    def complete(self, prompt: str, max_new_tokens: int) -> str:
        self.prompts.append(f"{prompt}|{max_new_tokens}")
        return "READY"

    def stream(self, prompt: str, max_new_tokens: int) -> Iterable[str]:
        self.prompts.append(f"{prompt}|{max_new_tokens}")
        return iter(("RE", "ADY"))

    def close(self) -> None:
        return None


def test_build_request_prompt_preserves_system_and_bounds_history() -> None:
    prompt = build_request_prompt(
        [
            {"role": "system", "content": "You are Jarvis."},
            {"role": "user", "content": "older"},
            {"role": "assistant", "content": "earlier answer"},
            {"role": "user", "content": "newest"},
        ],
        "context " * (MAX_CONTEXT_WORDS + 10),
    )

    assert "SYSTEM INSTRUCTIONS:\nYou are Jarvis." in prompt
    assert "User: older" in prompt
    assert "Assistant: earlier answer" in prompt
    assert "CURRENT USER REQUEST:\nnewest" in prompt
    history = prompt.split("PRIOR CONVERSATION:\n", 1)[1].split(
        "\n\nCURRENT USER REQUEST:", 1
    )[0]
    assert len(history.split()) <= MAX_CONTEXT_WORDS


def test_health_models_and_nonstream_completion() -> None:
    backend = FakeBackend()
    client = create_app(backend).test_client()

    assert client.get("/healthz").get_json()["status"] == "ok"
    assert client.get("/v1/models").get_json()["data"][0]["id"] == "rkllm"

    status = client.get("/v1/dawn/status")
    assert status.status_code == 200
    assert status.get_json() == {
        "backend": "rkllm",
        "max_context_length": MODEL_CONTEXT_TOKENS,
        "model": "rkllm",
    }

    response = client.post(
        "/v1/chat/completions",
        json={"model": "rkllm", "messages": [{"role": "user", "content": "hello"}]},
    )
    body = response.get_json()
    assert response.status_code == 200
    assert body["object"] == "chat.completion"
    assert body["choices"][0]["message"]["content"] == "READY"
    assert backend.prompts == ["CURRENT USER REQUEST:\nhello|128"]


def test_stream_completion_is_sse() -> None:
    client = create_app(FakeBackend()).test_client()

    response = client.post(
        "/v1/chat/completions",
        json={
            "model": "rkllm",
            "stream": True,
            "max_tokens": 8,
            "messages": [{"role": "user", "content": "hello"}],
        },
    )

    body = response.get_data(as_text=True)
    assert response.status_code == 200
    assert response.content_type == "text/event-stream"
    assert '"content":"RE"' in body
    assert '"content":"ADY"' in body
    assert "data: [DONE]" in body


def test_request_validation_rejects_unknown_model_and_bad_messages() -> None:
    client = create_app(FakeBackend()).test_client()

    unknown = client.post(
        "/v1/chat/completions",
        json={"model": "other", "messages": [{"role": "user", "content": "hello"}]},
    )
    assert unknown.status_code == 404

    invalid = client.post("/v1/chat/completions", json={"messages": []})
    assert invalid.status_code == 400


def test_collector_tracks_native_generated_tokens() -> None:
    collector = QueuedResultCollector()
    result = RKLLMResult()
    result.perf.generate_tokens = 8

    collector(ctypes.pointer(result), RKLLM_RUN_NORMAL)
    collector(ctypes.pointer(result), RKLLM_RUN_FINISH)

    assert collector.generated_tokens == 8
    assert collector.finished is True

    backend = object.__new__(RKLLMBackend)
    backend._collector = collector
    backend._last_finish_reason = "stop"
    backend._record_finish_reason(8)
    assert backend.finish_reason == "length"

    collector.generated_tokens = 7
    backend._record_finish_reason(8)
    assert backend.finish_reason == "stop"


def test_finish_reason_is_exposed_for_nonstream_and_streaming() -> None:
    class LengthBackend(FakeBackend):
        finish_reason = "length"

    nonstream_client = create_app(LengthBackend()).test_client()
    nonstream = nonstream_client.post(
        "/v1/chat/completions",
        json={"model": "rkllm", "messages": [{"role": "user", "content": "hello"}]},
    )
    assert nonstream.get_json()["choices"][0]["finish_reason"] == "length"

    stream_client = create_app(LengthBackend()).test_client()
    stream = stream_client.post(
        "/v1/chat/completions",
        json={
            "model": "rkllm",
            "stream": True,
            "max_tokens": 8,
            "messages": [{"role": "user", "content": "hello"}],
        },
    )
    assert '"finish_reason":"length"' in stream.get_data(as_text=True)
