from collections.abc import Iterable

from aibrain_rkllm.service import (
    MAX_CONTEXT_WORDS,
    build_request_prompt,
    create_app,
)


class FakeBackend:
    model_id = "rkllm"

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


def test_build_request_prompt_is_stateless_and_bounds_context() -> None:
    prompt = build_request_prompt(
        [
            {"role": "system", "content": "ignored"},
            {"role": "user", "content": "older"},
            {"role": "assistant", "content": "ignored"},
            {"role": "user", "content": "newest"},
        ],
        "context " * (MAX_CONTEXT_WORDS + 10),
    )

    assert "CURRENT REQUEST:\nnewest" in prompt
    reference_context = prompt.split("REFERENCE CONTEXT:\n", 1)[1].split(
        "\n\nCURRENT REQUEST:", 1
    )[0]
    assert len(reference_context.split()) == MAX_CONTEXT_WORDS


def test_health_models_and_nonstream_completion() -> None:
    backend = FakeBackend()
    client = create_app(backend).test_client()

    assert client.get("/healthz").get_json()["status"] == "ok"
    assert client.get("/v1/models").get_json()["data"][0]["id"] == "rkllm"

    response = client.post(
        "/v1/chat/completions",
        json={"model": "rkllm", "messages": [{"role": "user", "content": "hello"}]},
    )
    body = response.get_json()
    assert response.status_code == 200
    assert body["object"] == "chat.completion"
    assert body["choices"][0]["message"]["content"] == "READY"
    assert backend.prompts == ["hello|128"]


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
