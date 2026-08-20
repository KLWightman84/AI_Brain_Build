# RKLLM tokenizer runtime candidate capture

This is a **data-acquisition gate**, not the token-aware trimming implementation.

It verifies the already-captured Qwen tokenizer and active RKLLM model hashes, downloads one
Python `tokenizers==0.21.4` wheel into a test-only cache, loads the exact tokenizer JSON from a
test-only virtual environment, and records the wheel/tokenizer/model hashes in a sanitized archive.

It does not modify DAWN, the RKLLM adapter, system packages, configuration, services, or ports.
The resulting runtime remains a candidate until its token counts are calibrated against native
RKLLM `prefill_tokens` telemetry on the active model.

Run `./test_run.sh` before publishing. The deployment wrapper must be invoked with an immutable
Git commit and outer-script SHA-256 verification.
