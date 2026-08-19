"""Validation helpers for the native RKLLM reinitialization gate."""

from __future__ import annotations

from .inference import PromptResponseCollector


def ready_response_is_valid(collector: PromptResponseCollector) -> bool:
    """Return whether one completed callback produced the exact test response."""

    return (
        collector.finished
        and not collector.errored
        and collector.text.strip() == "READY"
    )
