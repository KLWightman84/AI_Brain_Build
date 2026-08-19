from pathlib import Path

import pytest

from tools.export_qwen35_rkllm import (
    MAX_CONTEXT,
    NUM_NPU_CORES,
    QUANTIZED_ALGORITHM,
    QUANTIZED_DTYPE,
    TARGET_PLATFORM,
    convert,
)


class FakeRKLLM:
    def __init__(self, output: Path) -> None:
        self.output = output
        self.load_call: tuple[str, str] | None = None
        self.build_kwargs: dict[str, object] | None = None
        self.export_path: str | None = None

    def load_huggingface(self, *, model: str, device: str) -> int:
        self.load_call = (model, device)
        return 0

    def build(self, **kwargs: object) -> int:
        self.build_kwargs = kwargs
        return 0

    def export_rkllm(self, path: str) -> int:
        self.export_path = path
        self.output.write_text("test artifact")
        return 0


def test_convert_uses_fixed_rk3588_contract(tmp_path: Path) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    calibration_inputs = tmp_path / "inputs.json"
    calibration_inputs.write_text("[]")
    output = tmp_path / "output" / "model.rkllm"
    fake = FakeRKLLM(output)

    convert(model_dir, calibration_inputs, output, "cpu", lambda: fake)

    assert fake.load_call == (str(model_dir), "cpu")
    assert fake.build_kwargs == {
        "do_quantization": True,
        "optimization_level": 1,
        "quantized_dtype": QUANTIZED_DTYPE,
        "quantized_algorithm": QUANTIZED_ALGORITHM,
        "target_platform": TARGET_PLATFORM,
        "num_npu_core": NUM_NPU_CORES,
        "extra_qparams": None,
        "dataset": str(calibration_inputs),
        "hybrid_rate": 0,
        "max_context": MAX_CONTEXT,
    }
    assert fake.export_path == str(output)
    assert output.read_text() == "test artifact"


def test_convert_refuses_to_overwrite_existing_artifact(tmp_path: Path) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    calibration_inputs = tmp_path / "inputs.json"
    calibration_inputs.write_text("[]")
    output = tmp_path / "model.rkllm"
    output.write_text("existing artifact")

    with pytest.raises(ValueError, match="refusing to overwrite"):
        convert(model_dir, calibration_inputs, output, "cpu", lambda: FakeRKLLM(output))
