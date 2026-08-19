"""Gunicorn worker that releases the RKLLM handle during normal stack unwinding."""

from __future__ import annotations

from typing import Any

from gunicorn.workers.sync import SyncWorker


def release_backend(backend: Any) -> None:
    """Close the single native handle and leave observable shutdown evidence."""

    backend.close()
    print("RKLLM Gunicorn worker model released", flush=True)


class RKLLMSyncWorker(SyncWorker):
    """Sync worker that owns RKLLM cleanup outside its signal handler."""

    def run(self) -> None:
        try:
            super().run()
        finally:
            from .wsgi import backend

            release_backend(backend)
