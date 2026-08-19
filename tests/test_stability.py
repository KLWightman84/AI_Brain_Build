from pathlib import Path

import pytest

from aibrain_rkllm.stability import current_rss_kib, tail_range_kib


def test_current_rss_kib_reads_procfs_style_status(tmp_path: Path) -> None:
    status = tmp_path / "status"
    status.write_text("Name:\tpython\nVmRSS:\t  12345 kB\n")

    assert current_rss_kib(status) == 12345


def test_tail_range_uses_final_samples() -> None:
    assert tail_range_kib([100, 500, 105, 110, 115], tail_count=3) == 10


@pytest.mark.parametrize("samples,tail_count", [([], 20), ([1], 0)])
def test_tail_range_rejects_invalid_inputs(samples: list[int], tail_count: int) -> None:
    with pytest.raises(ValueError):
        tail_range_kib(samples, tail_count)
