from aibrain_rkllm.inference import PromptResponseCollector
from aibrain_rkllm.protocol import RKLLM_RUN_FINISH, RKLLM_RUN_NORMAL
from aibrain_rkllm.restart import ready_response_is_valid


def test_ready_response_requires_exact_completed_non_error_response() -> None:
    collector = PromptResponseCollector()
    assert ready_response_is_valid(collector) is False

    collector.finished = True
    assert ready_response_is_valid(collector) is False

    collector.reset()
    collector.pieces.append("READY")
    collector.finished = True
    assert ready_response_is_valid(collector) is True

    collector.errored = True
    assert ready_response_is_valid(collector) is False
