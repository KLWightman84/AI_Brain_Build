from pathlib import Path

import pytest

from aibrain_rkllm import native


def test_loads_shared_library(monkeypatch):
    sentinel = object()
    monkeypatch.setattr(native.ctypes, "CDLL", lambda path: sentinel)
    assert native.load_rkllm_library(Path("/lib/librkllmrt.so")) is sentinel


def test_reports_load_failure(monkeypatch):
    def fail(_: str):
        raise OSError("missing dependency")

    monkeypatch.setattr(native.ctypes, "CDLL", fail)
    with pytest.raises(native.NativeLibraryError, match="librkllmrt.so"):
        native.load_rkllm_library(Path("/lib/librkllmrt.so"))
