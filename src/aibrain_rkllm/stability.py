"""Small, dependency-free measurements for RKLLM stability gates."""

from __future__ import annotations

from pathlib import Path


def current_rss_kib(status_path: Path = Path("/proc/self/status")) -> int:
    """Return current resident memory from Linux procfs in KiB."""
    for line in status_path.read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    raise RuntimeError(f"VmRSS was not found in {status_path}")


def tail_range_kib(samples: list[int], tail_count: int = 20) -> int:
    """Return the resident-memory range over the final measurement window."""
    if not samples:
        raise ValueError("at least one memory sample is required")
    if tail_count <= 0:
        raise ValueError("tail_count must be positive")
    window = samples[-tail_count:]
    return max(window) - min(window)
