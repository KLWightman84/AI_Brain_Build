from aibrain_rkllm.gunicorn_worker import release_backend


class FakeBackend:
    def __init__(self) -> None:
        self.close_calls = 0

    def close(self) -> None:
        self.close_calls += 1


def test_release_backend_closes_the_native_owner_once(capsys) -> None:
    backend = FakeBackend()

    release_backend(backend)

    assert backend.close_calls == 1
    assert "model released" in capsys.readouterr().out
