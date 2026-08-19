from collections.abc import Callable
from threading import Lock
from typing import Any


class RKLLMHandleOwner:
    """Own an initialized native RKLLM handle and release it at most once."""

    def __init__(self, handle: Any, destroy: Callable[[Any], int]) -> None:
        self._handle = handle
        self._destroy = destroy
        self._closed = False
        self._lock = Lock()

    @property
    def closed(self) -> bool:
        with self._lock:
            return self._closed

    def close(self) -> bool:
        """Release the native handle once; return whether this call released it."""
        with self._lock:
            if self._closed:
                return False
            self._closed = True
            handle = self._handle
        result = self._destroy(handle)
        if result != 0:
            raise RuntimeError(f"rkllm_destroy failed with rc={result}")
        return True

    def __enter__(self) -> "RKLLMHandleOwner":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
