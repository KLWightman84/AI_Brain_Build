# Qwen3.5 4B RKLLM test artifact

This record identifies the first clean-rebuild RKLLM artifact. The binary is **not** committed to Git; it remains a test artifact until it passes native Orange Pi acceptance.

## Artifact

| Field | Value |
| --- | --- |
| Filename | `Qwen3.5-4B_w8a8_rk3588_ctx4096.rkllm` |
| Size | 5.2 GiB (displayed size) |
| SHA-256 | `f733cb8acc42fc8ce486c965f673da7918fbc1a1a6ae22c7991e389c34963056` |
| Status | Conversion succeeded; Pi load/inference acceptance is still pending |

## Conversion contract

| Field | Value |
| --- | --- |
| Source | `Qwen/Qwen3.5-4B` from Hugging Face |
| Toolkit | Rockchip RKLLM Toolkit 1.3.0 |
| Reference | `airockchip/rknn-llm` tag `release-v1.3.0`, commit `878f9361fd3afa7e167b7079918918f78d2c1c2a` |
| Target | `rk3588` |
| NPU cores | 3 |
| Quantization | W8A8, `normal` algorithm |
| Optimization level | 1 |
| Context limit | 4096 |
| Conversion device | CPU under WSL 2 |
| Wrapper | `tools/export_qwen35_rkllm.py` |

## Calibration note

The official v1.3.0 Qwen3.5 preparation script produced `data/llm_inputs.json` from its 20 bundled image-text samples. The accompanying upstream README/example exporter refers to `data/inputs.json`; the generated `llm_inputs.json` is the actual manifest used for this conversion.

## Scope

RKLLM emitted the expected notice that it exports `Qwen3_5ForCausalLM` from the vision-capable `Qwen3_5ForConditionalGeneration` source. This artifact is therefore the language model used for DAWN; no vision runtime is part of the current clean rebuild.

## Required next acceptance gates

1. Transfer to the Pi **test** model tree and verify SHA-256.
2. Initialize with the v1.3.0 ARM64 runtime under the `ai_brain` account.
3. Run single inference, repeated inference, memory-plateau, shutdown/restart, and reboot acceptance tests.
4. Promote only after those gates pass; do not use this artifact as production solely because conversion succeeded.
