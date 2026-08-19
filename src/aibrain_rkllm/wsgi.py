"""Gunicorn entry point for the single-worker loopback RKLLM service."""

from __future__ import annotations

import atexit

from .wsgi_factory import build_wsgi_application

app, backend = build_wsgi_application()
atexit.register(backend.close)
