import pytest

from aibrain_rkllm.recovery import DEFAULT_OVERSIZE_WORD_COUNT, oversized_prompt


def test_oversized_prompt_exceeds_context_limit() -> None:
    prompt = oversized_prompt()

    assert prompt.count(" ") + 1 == DEFAULT_OVERSIZE_WORD_COUNT
    assert prompt.startswith("x x x")


@pytest.mark.parametrize("word_count", [0, 4095, 4096])
def test_oversized_prompt_rejects_non_oversized_requests(word_count: int) -> None:
    with pytest.raises(ValueError, match="must exceed"):
        oversized_prompt(word_count)
