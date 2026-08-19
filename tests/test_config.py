from pathlib import Path
import pytest

from aibrain_rkllm.config import ServiceConfig


def config(**changes):
    base = {"model_path": Path("/models/4b.rkllm"), "library_path": Path("/lib/librkllmrt.so")}
    base.update(changes)
    return ServiceConfig(**base)


def test_preserved_service_contract_is_valid():
    config().validate()

@pytest.mark.parametrize("changes", [
    {"host": "0.0.0.0"},
    {"port": 8080},
    {"target_platform": "rk3576"},
    {"max_context_length": 8192},
])
def test_rejects_unverified_contract_changes(changes):
    with pytest.raises(ValueError):
        config(**changes).validate()
