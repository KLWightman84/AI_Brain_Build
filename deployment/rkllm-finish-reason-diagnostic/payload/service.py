"""Loopback-only, OpenAI-style HTTP service over the verified RKLLM runtime."""

from __future__ import annotations

import ctypes
import json
import queue
import threading
import time
import uuid
from collections.abc import Generator, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from flask import Flask, Response, jsonify, request, stream_with_context

from .inference import PromptResponseCollector, run_prompt
from .model import InitializedRKLLMModel, initialize_model
from .native import load_rkllm_library
from .protocol import (\n    RKLLMResult,\n    RKLLM_RUN_ERROR,\n    RKLLM_RUN_FINISH,\n    RKLLM_RUN_NORMAL,\n    RKLLM_RUN_WAITING,\n)

SERVICE_NAME = "aibrain-rkllm"
MODEL_ID = "rkllm"
MAX_CONTEXT_WORDS = 2400
MAX_NEW_TOKENS = 768
MODEL_CONTEXT_TOKENS = 4096


class CompletionBackend(Protocol):
    model_id: str

    def complete(self, prompt: str, max_new_tokens: int) -> str: ...

    def stream(self, prompt: str, max_new_tokens: int) -> Iterable[str]: ...

    def close(self) -> None: ...


@dataclass
class QueuedResultCollector(PromptResponseCollector):
    """Collect callback text and expose each fragment to one SSE generator."""

    chunks: queue.Queue[str] = field(default_factory=queue.Queue)
    diagnostic_events: list[dict[str, int | bool]] = field(default_factory=list)

    def reset(self) -> None:
        super().reset()
        self.diagnostic_events.clear()
        while True:
            try:
                self.chunks.get_nowait()
            except queue.Empty:
                return

    def __call__(self, result: ctypes.POINTER(RKLLMResult), state: int) -> int:
        has_text = bool(state == RKLLM_RUN_NORMAL and result and result.contents.text)
        self.diagnostic_events.append(
            {
                "state": int(state),
                "token_id": int(result.contents.token_id) if result else -1,
                "has_text": has_text,
                "text_bytes": len(result.contents.text) if has_text else 0,
                "perf_generate_tokens": int(result.contents.perf.generate_tokens)
                if result
                else 0,
            }
        )
        if state == RKLLM_RUN_NORMAL and result and result.contents.text:
            piece = result.contents.text.decode("utf-8", errors="replace")
            self.pieces.append(piece)
            self.chunks.put(piece)
        elif state == RKLLM_RUN_FINISH:
            self.finished = True
        elif state == RKLLM_RUN_ERROR:
            self.errored = True
        return 0


class RKLLMBackend:
    """A single serialized RKLLM model for synchronous and SSE requests."""

    model_id = MODEL_ID

    def __init__(self, library: Any, model: InitializedRKLLMModel) -> None:
        self._library = library
        self._model = model
        self._collector = QueuedResultCollector()
        self._lock = threading.Lock()
        self._closed = False
        self._bind_control_calls()

    @classmethod
    def load(cls, library_path: Path, model_path: Path) -> "RKLLMBackend":
        library = load_rkllm_library(library_path)
        collector = QueuedResultCollector()
        model = initialize_model(library, model_path, result_handler=collector)
        backend = cls(library, model)
        backend._collector = collector
        return backend

    def _bind_control_calls(self) -> None:
        self._library.rkllm_abort.argtypes = [ctypes.c_void_p]
        self._library.rkllm_abort.restype = ctypes.c_int
        self._library.rkllm_is_running.argtypes = [ctypes.c_void_p]
        self._library.rkllm_is_running.restype = ctypes.c_int

    def _ensure_open(self) -> None:
        if self._closed:
            raise RuntimeError("RKLLM service backend is closed")

    def _assert_finished(self) -> None:
        if self._collector.errored:
            raise RuntimeError("RKLLM callback reported an error")
        if not self._collector.finished:
            raise RuntimeError("RKLLM callback did not report completion")

    def complete(self, prompt: str, max_new_tokens: int) -> str:
        with self._lock:
            self._ensure_open()
            self._collector.reset()
            run_prompt(self._library, self._model, prompt, max_new_tokens=max_new_tokens)
            self._assert_finished()
            response = self._collector.text.strip()
            if not response:
                raise RuntimeError("RKLLM returned an empty response")
            return response

    def stream(self, prompt: str, max_new_tokens: int) -> Generator[str, None, None]:
        """Yield callback fragments while one serialized native run is active."""

        def generate() -> Generator[str, None, None]:
            with self._lock:
                self._ensure_open()
                self._collector.reset()
                error: list[BaseException] = []

                def worker() -> None:
                    try:
                        run_prompt(
                            self._library,
                            self._model,
                            prompt,
                            max_new_tokens=max_new_tokens,
                        )
                    except BaseException as exc:
                        error.append(exc)

                thread = threading.Thread(target=worker, name="aibrain-rkllm-inference")
                thread.start()
                completed = False
                try:
                    while thread.is_alive() or not self._collector.chunks.empty():
                        try:
                            yield self._collector.chunks.get(timeout=0.1)
                        except queue.Empty:
                            continue
                    thread.join()
                    if error:
                        raise RuntimeError(f"RKLLM streaming run failed: {error[0]}")
                    self._assert_finished()
                    completed = True
                finally:
                    if thread.is_alive():
                        self.abort()
                        thread.join(timeout=5)
                        if thread.is_alive():
                            raise RuntimeError("RKLLM worker did not stop after abort")
                    if not completed and not error and self._collector.errored:
                        raise RuntimeError("RKLLM streaming callback reported an error")

        return generate()

    @property
    def diagnostic_events(self) -> list[dict[str, int | bool]]:
        return list(self._collector.diagnostic_events)

    def abort(self) -> None:
        """Abort an active native request without releasing the model handle."""
        if self._closed:
            return
        if self._library.rkllm_is_running(self._model.handle) == 1:
            result = self._library.rkllm_abort(self._model.handle)
            if result != 0:
                raise RuntimeError(f"rkllm_abort failed with rc={result}")

    def close(self) -> None:
        """Abort if needed and release the sole native handle exactly once."""
        if self._closed:
            return
        self.abort()
        with self._lock:
            if self._closed:
                return
            self._model.close()
            self._closed = True


def _text_content(message: dict[str, object]) -> str:
    content = message.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        text_parts: list[str] = []
        for part in content:
            if not isinstance(part, dict) or part.get("type") != "text":
                raise ValueError("message content parts must be text parts")
            text = part.get("text")
            if not isinstance(text, str):
                raise ValueError("message text parts must contain a string")
            text_parts.append(text)
        return " ".join(text_parts)
    raise ValueError("message content must be a string or text-part array")


def _tail_words(text: str, maximum: int) -> str:
    if maximum <= 0:
        return ""
    words = text.split()
    return " ".join(words[-maximum:])


def build_request_prompt(messages: object, dawn_context: object = "") -> str:
    """Build one stateless prompt while preserving DAWN's message semantics."""
    if not isinstance(messages, list) or not messages:
        raise ValueError("'messages' must be a non-empty array")
    if not isinstance(dawn_context, str):
        raise ValueError("'dawn_context' must be a string")

    normalized: list[tuple[str, str]] = []
    current_index = -1
    for message in messages:
        if not isinstance(message, dict):
            raise ValueError("each message must be an object")
        role = message.get("role")
        if not isinstance(role, str):
            raise ValueError("message role must be a string")
        if role not in ("system", "user", "assistant", "tool"):
            continue

        content = _text_content(message)
        normalized.append((role, content))
        if role in ("user", "tool") and content.strip():
            current_index = len(normalized) - 1

    if current_index < 0:
        raise ValueError("messages must contain a non-empty user or tool message")

    system_parts: list[str] = []
    history_parts: list[str] = []
    if dawn_context.strip():
        history_parts.append(f"Additional reference context: {dawn_context}")

    for role, content in normalized[:current_index]:
        if not content.strip():
            continue
        if role == "system":
            system_parts.append(content)
        else:
            history_parts.append(f"{role.capitalize()}: {content}")

    current_role, current_text = normalized[current_index]
    system_text = "\n\n".join(system_parts)
    reference_text = "\n\n".join(history_parts)
    reserved_words = len(system_text.split()) + len(current_text.split())
    bounded_history = _tail_words(reference_text, MAX_CONTEXT_WORDS - reserved_words)

    parts: list[str] = []
    if system_text:
        parts.append(f"SYSTEM INSTRUCTIONS:\n{system_text}")
    if bounded_history:
        parts.append(f"PRIOR CONVERSATION:\n{bounded_history}")

    current_label = "CURRENT USER REQUEST" if current_role == "user" else "CURRENT TOOL RESULT"
    parts.append(f"{current_label}:\n{current_text}")
    return "\n\n".join(parts)


def _parse_max_tokens(value: object) -> int:
    if value is None:
        return 128
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("'max_tokens' must be an integer")
    if not 1 <= value <= MAX_NEW_TOKENS:
        raise ValueError(f"'max_tokens' must be between 1 and {MAX_NEW_TOKENS}")
    return value


def _completion_response(model_id: str, content: str) -> dict[str, object]:
    now = int(time.time())
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex}",
        "object": "chat.completion",
        "created": now,
        "model": model_id,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
    }


def _sse(payload: object) -> str:
    return f"data: {json.dumps(payload, separators=(',', ':'))}\n\n"


def create_app(backend: CompletionBackend) -> Flask:
    """Create the service app without binding a network socket."""

    app = Flask(__name__)

    @app.get("/healthz")
    def healthz() -> Response:
        return jsonify(
            {"status": "ok", "service": SERVICE_NAME, "model": backend.model_id}
        )

    @app.get("/v1/dawn/status")
    def dawn_status() -> Response:
        """Expose the RKLLM artifact context limit DAWN needs for safe budgeting."""
        return jsonify(
            {
                "backend": "rkllm",
                "model": backend.model_id,
                "max_context_length": MODEL_CONTEXT_TOKENS,
            }
        )

    @app.get("/v1/dawn/last-run-diagnostics")
    def last_run_diagnostics() -> Response:
        """Temporary loopback-only callback metadata for Stage 1 probing."""
        events = getattr(backend, "diagnostic_events", [])
        return jsonify({"events": events})

    @app.get("/v1/models")
    def models() -> Response:
        return jsonify(
            {
                "object": "list",
                "data": [
                    {
                        "id": backend.model_id,
                        "object": "model",
                        "owned_by": "rkllm",
                    }
                ],
            }
        )

    @app.post("/v1/chat/completions")
    def chat_completions() -> Response:
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            return jsonify({"error": {"message": "request body must be a JSON object"}}), 400
        try:
            prompt = build_request_prompt(
                data.get("messages"), data.get("dawn_context", "")
            )
            max_new_tokens = _parse_max_tokens(data.get("max_tokens"))
            stream = data.get("stream", False)
            if not isinstance(stream, bool):
                raise ValueError("'stream' must be a boolean")
        except ValueError as error:
            return jsonify({"error": {"message": str(error)}}), 400

        model_id = data.get("model", backend.model_id)
        if model_id != backend.model_id:
            return jsonify({"error": {"message": f"unknown model: {model_id}"}}), 404

        if not stream:
            try:
                return jsonify(
                    _completion_response(
                        backend.model_id,
                        backend.complete(prompt, max_new_tokens),
                    )
                )
            except RuntimeError as error:
                return jsonify({"error": {"message": str(error)}}), 503

        stream_id = f"chatcmpl-{uuid.uuid4().hex}"

        def events() -> Generator[str, None, None]:
            yield _sse(
                {
                    "id": stream_id,
                    "object": "chat.completion.chunk",
                    "model": backend.model_id,
                    "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}],
                }
            )
            try:
                for chunk in backend.stream(prompt, max_new_tokens):
                    yield _sse(
                        {
                            "id": stream_id,
                            "object": "chat.completion.chunk",
                            "model": backend.model_id,
                            "choices": [{"index": 0, "delta": {"content": chunk}, "finish_reason": None}],
                        }
                    )
                yield _sse(
                    {
                        "id": stream_id,
                        "object": "chat.completion.chunk",
                        "model": backend.model_id,
                        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    }
                )
                yield "data: [DONE]\n\n"
            except RuntimeError as error:
                yield _sse({"error": {"message": str(error)}})

        return Response(
            stream_with_context(events()),
            content_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    return app
