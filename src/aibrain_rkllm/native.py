import ctypes
from pathlib import Path


class NativeLibraryError(RuntimeError):
    """The required RKLLM shared library could not be loaded."""


def load_rkllm_library(library_path: Path) -> ctypes.CDLL:
    """Load the RKLLM runtime without initializing a model handle."""
    try:
        return ctypes.CDLL(str(library_path))
    except OSError as error:
        raise NativeLibraryError(
            f"Unable to load RKLLM runtime library: {library_path}: {error}"
        ) from error
