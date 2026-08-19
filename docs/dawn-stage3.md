# DAWN stage 3 — minimal RKLLM integration

## Goal

Prove one narrow path:

```text
DAWN (server-only, no tools) → 127.0.0.1:8081 → RKLLM 4B → valid reply
```

This is not a DAWN production deployment. Do not enable WebUI, local audio,
AEC, STT, wake word, Piper, deterministic tools, memory, scheduling, cloud
providers, or external integrations during this stage.

## Source provenance

The preserved DAWN source records original upstream
`The-OASIS-Project/dawn` at
`63ef6de2feb6c8463b64c91d2f0cae596e4e2b17`. That commit has been removed
from the upstream server and cannot be fetched. The immutable archive copy
under `/srv/aibrain/test/AI-clean-slate-reference/dawn/source` is therefore
the only exact source reference.

A current upstream checkout may be used only as an unapproved comparison
candidate. It must not silently replace the archived source or become a
production dependency.

## Test-source preparation

Never configure or modify the archived source directly after the initial
compatibility inventory. Use
`tools/prepare_dawn_stage3_source.py` to copy it to a distinct directory under
`/srv/aibrain/test/builds/`.

The preparer excludes backup, experiment, and secret-like residue. It makes
reviewed changes only in the generated copy:

1. Gates the archive's otherwise unconditional Recall registration and
   compilation with `DAWN_ENABLE_RECALL_TOOL`.
2. When `DAWN_ENABLE_TTS_TOOL=OFF`, replaces DAWN's unconditional native TTS
   sources with a no-op implementation and removes Piper, piper-phonemize,
   eSpeak, and ONNX Runtime from its link dependencies.
3. Replaces the inactive ONNX embedding provider and Silero VAD provider with
   fail-closed stubs, so absent ONNX Runtime cannot become an accidental
   dependency.
4. Keeps the archive's local SQLite contacts/calendar support sources and
   explicitly gates WebUI-only session/attention calls. No user-facing memory,
   calendar, attention, TTS, or recall feature is enabled.

These changes keep this narrow stage from installing or activating Piper,
ONNX Runtime, a voice service, an embedding service, or a WebUI early. They
do not modify the preserved male voice models and do not alter the production
Piper, semantic-memory, calendar, or attention plans.

The archive stays unchanged; the generated test source is disposable.

## Build contract

Use `cmake/dawn-stage3-minimal.cmake` as an initial cache against the
generated test source. It sets `SERVER_ONLY=ON`, disables all optional user
interfaces and audio extras, and disables every legacy DAWN tool at compile
time. The CMake build directory must remain below
`/srv/aibrain/test/builds/`.

The accepted RKLLM gateway remains:

| Field | Value |
| --- | --- |
| Endpoint | `http://127.0.0.1:8081` |
| Model | `rkllm` |
| Vision | disabled |
| Artifact context limit | 4096 |
| Production gateway | `aibrain-rkllm.service` |

The archived `max_tokens = 16384` value is incompatible with the 4096-token
artifact limit and must not be carried forward.

## Promotion rule

No DAWN source, configuration, unit, or runtime state moves to
`/srv/aibrain/production/` until this minimal test service has passed direct
DAWN-to-RKLLM acceptance and a controlled restart.
