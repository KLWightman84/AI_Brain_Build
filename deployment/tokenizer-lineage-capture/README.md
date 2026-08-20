# Tokenizer-Lineage Capture

This pilot is the required evidence step before implementing exact
token-aware context trimming for the active 4,096-token RKLLM model.

It is read-only outside a new timestamped archive in
`/srv/aibrain/test/captures/`. It does **not** restart services, modify source
or configuration, install packages, download a tokenizer, or copy model data.

The runner records the active model's path, size, and SHA-256; the RKLLM
adapter's documented tokenizer-related contract; tokenizer-shaped assets found
in approved local roots; and file-name-only conversion-lineage hints.

Candidate files are not treated as compatible merely because their names look
right. A future implementation requires all three of the following:

1. an exact tokenizer revision and SHA-256 tied to the active RKLLM conversion;
2. an empirically measured native chat-envelope reserve using RKLLM prefill
   telemetry; and
3. model-backed tests showing that the entire serialized prompt plus requested
   output fits in the 4,096-token context.

## Local validation

```bash
bash deployment/tokenizer-lineage-capture/run.sh --self-test
```

## Intended target execution

The published pilot will be run as a hash-locked single command. Its output is
an evidence archive for review, not an implementation or deployment.
