from concurrent.futures import ThreadPoolExecutor

from aibrain_rkllm.lifecycle import RKLLMHandleOwner


def test_close_releases_once():
    calls = []
    owner = RKLLMHandleOwner("handle", lambda handle: calls.append(handle) or 0)
    assert owner.close() is True
    assert owner.close() is False
    assert owner.closed is True
    assert calls == ["handle"]


def test_context_manager_releases_on_error():
    calls = []
    try:
        with RKLLMHandleOwner("handle", lambda handle: calls.append(handle) or 0):
            raise ValueError("test error")
    except ValueError:
        pass
    assert calls == ["handle"]


def test_concurrent_close_releases_once():
    calls = []
    owner = RKLLMHandleOwner("handle", lambda handle: calls.append(handle) or 0)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: owner.close(), range(32)))
    assert results.count(True) == 1
    assert calls == ["handle"]
