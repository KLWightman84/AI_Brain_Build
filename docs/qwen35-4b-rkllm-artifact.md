# Qwen3.5 4B RKLLM test artifact

This record identifies the first clean-rebuild RKLLM artifact. The binary is **not** committed to Git; it remains a test artifact until it passes native Orange Pi acceptance.

## Artifact

| Field | Value |
| --- | --- |
| Filename | `Qwen3.5-4B_w8a8_rk3588_ctx4096.rkllm` |
| Size | 5.2 GiB (displayed size) |
| SHA-256 | `f733cb8acc42fc8ce486c965f673da7918fbc1a1a6ae22c7991e389c34963056` |
| Status | Pi initialization, prompt, repeat-stability, oversized-context recovery, and native reinitialization passed; reboot and service gates remain |

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

## Pi acceptance evidence

- SHA-256 matched after direct local-network transfer to `/srv/aibrain/test/models/`.
- On the Orange Pi 5 Plus, RKLLM Runtime 1.3.0 accepted the artifact with RKNPU driver 0.9.7, `max_context_limit: 4096`, `npu_core_num: 3`, and `model_dtype: W8A8`.
- The load-only smoke test passed and released the native handle cleanly.
- The first stateless prompt test returned exactly `READY`, reported completion, and released the native handle cleanly.
- The 100-request stateless repeat test returned `READY` for both the first and last request in 104.216 seconds. RSS was 4,799,824 KiB after initialization and 4,822,716 KiB at final/peak (about +22 MiB); the final 20-request range was 0 KiB. The handle released cleanly. Its JSON report remains test-only at `/srv/aibrain/test/logs/rkllm-repeat-001.json`.
- The oversized-context recovery gate deliberately sent 6,012 tokens against the 4,096-token limit. RKLLM rejected it with a native context-length error; the same loaded model then returned `READY` to a new short request and released cleanly. Its JSON report remains test-only at `/srv/aibrain/test/logs/rkllm-oversize-recovery-001.json`.
- The native reinitialization gate completed three successive load → prompt → release cycles. Every cycle returned `READY`; each native handle reported a first, successful release. Its JSON report remains test-only at `/srv/aibrain/test/logs/rkllm-reinitialize-001.json`.

## Required next acceptance gates

1. Reboot the Orange Pi, confirm eMMC root and NVMe mount, then rerun a fresh RKLLM prompt smoke test.
2. Add the loopback-only DAWN service endpoint and test non-streaming and streaming requests, including a systemd-managed restart.
3. Promote only after all gates pass; do not use this artifact as production solely because these test gates succeeded.
