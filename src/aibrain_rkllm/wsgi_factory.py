"""Configuration-backed construction for the Gunicorn RKLLM WSGI worker."""

from __future__ import annotations

import os
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from flask import Flask

from .config import ServiceConfig
from .service import RKLLMBackend, create_app

LIBRARY_ENV = "AIBRAIN_RKLLM_LIBRARY"
MODEL_ENV = "AIBRAIN_RKLLM_MODEL"
BackendLoader = Callable[[Path, Path], Any]


def build_wsgi_application(
    environment: Mapping[str, str] | None = None,
    backend_loader: BackendLoader = RKLLMBackend.load,
) -> tuple[Flask, Any]:
    """Load the single RKLLM backend required by one Gunicorn worker."""

    environment = environment or os.environ
    library_value = environment.get(LIBRARY_ENV)
    model_value = environment.get(MODEL_ENV)
    if not library_value:
        raise RuntimeError(f"{LIBRARY_ENV} must be set")
    if not model_value:
        raise RuntimeError(f"{MODEL_ENV} must be set")

    config = ServiceConfig(
        library_path=Path(library_value),
        model_path=Path(model_value),
    )
    config.validate()
    backend = backend_loader(config.library_path, config.model_path)
    return create_app(backend), backend
