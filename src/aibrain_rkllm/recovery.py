"""Recovery helpers for the RKLLM oversized-context acceptance gate."""

from __future__ import annotations

from .model import MAX_CONTEXT_LENGTH

DEFAULT_OVERSIZE_WORD_COUNT = 6000


def oversized_prompt(word_count: int = DEFAULT_OVERSIZE_WORD_COUNT) -> str:
    """Return a deliberately over-context, whitespace-tokenized test prompt.

    The prompt is intentionally test-only.  Its size exceeds the validated
    4096-token context ceiling even if each `x` maps to a single token.
    """

    if word_count <= MAX_CONTEXT_LENGTH:
        raise ValueError(
            f"word_count must exceed the {MAX_CONTEXT_LENGTH}-token context limit"
        )
    return " ".join(["x"] * word_count)
