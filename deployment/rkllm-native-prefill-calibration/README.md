# RKLLM native prefill calibration

This pilot verifies the candidate Qwen tokenizer against the active RKLLM runtime's own
`perf.prefill_tokens` callback telemetry. It is deliberately separate from token-aware trimming.

Before it runs, the installer hash-checks the captured dirty adapter closure, the active model,
the candidate tokenizer, and its test-only wheel. It saves `service.py`, replaces it temporarily
with a telemetry build, tests that build, restarts the loopback-only RKLLM service, then sends six
non-sensitive calibration prompts. The archive contains counts and deltas only — never prompts,
conversation history, or generated text.

The installer restores the exact pre-calibration source, restarts the service, reruns the existing
adapter tests, and checks its original SHA-256 before creating the evidence archive. Any error
after replacement invokes the same restoration path. It does not retain telemetry or alter
trimming behavior.

Run `bash deployment/rkllm-native-prefill-calibration/test_run.sh` before publishing. A successful
calibration archive is required before designing the final token-aware trimming integration.
