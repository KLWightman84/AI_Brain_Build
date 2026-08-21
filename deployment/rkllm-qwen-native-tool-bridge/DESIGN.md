# Qwen native-tool bridge pilot

## Problem

DAWN sends OpenAI-compatible `tools` and expects OpenAI SSE `delta.tool_calls`.
The local RKLLM adapter previously discarded those fields and emitted only text, so
DAWN never entered its tool loop.

## Scope

This pilot changes only the RKLLM HTTP adapter. It preserves:

- DAWN as conversation/context owner;
- the installed calibrated tokenizer budget;
- the existing tool registry and maintenance tool;
- loopback-only RKLLM operation;
- no new shell, privilege, restart, or file-write capability.

## Translation contract

1. Validate DAWN's offered OpenAI function schemas.
2. Render those schemas in Qwen's documented `<tools>` / `<tool_call>` form.
3. Accept a Qwen tool call only if its name was offered and its arguments are a JSON object.
4. Convert accepted calls into OpenAI-style `tool_calls`, with compact JSON arguments and
   `finish_reason: "tool_calls"`.
5. Treat malformed or unoffered tags as ordinary text — never as an executable call.

The adapter buffers only turns that have offered tools so tool markup cannot leak into the
chat stream. Ordinary non-tool turns retain streaming.

## Acceptance gates

The installer:

1. requires exact hashes for the verified token-aware adapter files;
2. backs up the source files;
3. runs the adapter's deterministic tests;
4. restarts only `aibrain-rkllm.service`;
5. verifies loopback health;
6. issues a synthetic, non-executable `protocol_probe` tool request and requires the
   adapter to return an OpenAI `tool_calls` result;
7. restores the original files and service if any gate fails.

A successful installer is followed by one WebUI test:
`Jarvis, run a maintenance inspection.`
