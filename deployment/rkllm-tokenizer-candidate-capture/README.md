# RKLLM Tokenizer Candidate Capture

This pilot acquires only `tokenizer.json` for the documented
`Qwen/Qwen3.5-4B` source at a pinned 40-character revision. It writes the
asset under the test tree, fingerprints both the tokenizer and the active
RKLLM model, and creates a small sanitized evidence archive.

The tokenizer is a **candidate**, not a certified runtime dependency. A later
calibration must compare exact tokenizer counts of the adapter's serialized
prompts against RKLLM's native prefill telemetry before the adapter may use it
for context trimming. This pilot does not install a Python package or change
the service, model, configuration, or systemd environment.
