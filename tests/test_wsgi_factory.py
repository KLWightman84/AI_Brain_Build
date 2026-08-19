import pytest

from aibrain_rkllm.wsgi_factory import (
    LIBRARY_ENV,
    MODEL_ENV,
    build_wsgi_application,
)


class FakeBackend:
    model_id = "rkllm"

    def complete(self, _prompt: str, _max_new_tokens: int) -> str:
        return "READY"

    def stream(self, _prompt: str, _max_new_tokens: int):
        return iter(())

    def close(self) -> None:
        return None


def test_wsgi_factory_loads_one_backend_with_fixed_service_config() -> None:
    seen = []

    def loader(library, model):
        seen.append((library, model))
        return FakeBackend()

    app, backend = build_wsgi_application(
        {LIBRARY_ENV: "/tmp/runtime.so", MODEL_ENV: "/tmp/model.rkllm"},
        backend_loader=loader,
    )

    assert backend.model_id == "rkllm"
    assert seen == [("/tmp/runtime.so", "/tmp/model.rkllm")]
    assert app.test_client().get("/healthz").status_code == 200


@pytest.mark.parametrize("environment, variable", [({}, LIBRARY_ENV), ({LIBRARY_ENV: "/x"}, MODEL_ENV)])
def test_wsgi_factory_requires_both_runtime_paths(environment, variable) -> None:
    with pytest.raises(RuntimeError, match=variable):
        build_wsgi_application(environment, backend_loader=lambda *_: FakeBackend())
