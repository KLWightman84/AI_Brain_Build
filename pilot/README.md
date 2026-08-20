# Stage-3 WebUI/TTS/RKLLM Pilot Provenance

Status: verified pilot snapshot only. This material is not a standalone clean
rebuild and must not be merged into `main` or used as an installer.

## Captured evidence

- Capture archive: `evidence/pilot-state-capture-20260820-143924.tar.gz`
- Archive SHA-256: `c2130744ffd0829bad16fbbb2dc986f97ca03577f6875721a639e04ce3e7464b`
- Capture time: 2026-08-20T14:39:32-04:00
- Captured adapter base: `9ed366587bc409389665536caba061eb9fc95e36`
- Active endpoints: RKLLM `127.0.0.1:8081`; WebUI `127.0.0.1:3000`

The archive passed its allowlist and tar-integrity checks on the Pi. Codex
verified the uploaded archive's outer SHA-256 and every captured payload hash.
The embedded `SHA256SUMS` stores the ephemeral capture-stage path as an
absolute prefix; for portable verification, remove the exact
`/srv/aibrain/test/captures/.pilot-state-capture.<suffix>/` prefix before
running `sha256sum -c`. This is a capture-format defect, not a source change.

## Accepted pilot state

- RKLLM adapter preserves system instructions and prior conversation context,
  and accepts up to 768 new tokens. The captured dependency-free test runner
  and controlled 768-token marker test passed.
- The rejected finish-reason and continuation work is absent. The adapter still
  reports `finish_reason: "stop"`; no continuation behavior is authorized.
- DAWN WebUI is compiled with Phone and Volume tools disabled, while retaining
  link-safe Phone/SMS stubs and the WebUI-only volume parser.
- ASR is Whisper `small.en`, beam-search size 6.
- Alan Piper TTS uses `en_GB-alan-medium`, `length_scale = 1.08`, and an
  explicit private eSpeak data path. The user service is active with a 300-second
  RKLLM Gunicorn timeout.
- The archive records exact active model hashes, selected CMake settings,
  user-unit text, accepted patches, dependency paths, and service evidence.

## Rebuild blockers

Before a clean, reproducible rebuild or installer is designed, capture and
review these missing inputs:

1. A canonical DAWN source revision or source-archive hash, plus the `www/`
   frontend and vendored `whisper.cpp` provenance.
2. Piper source remote/tag and configure arguments; ONNX Runtime/eSpeak bundle
   hashes; header-symlink provenance; and an environment-aware `libucd.so`
   resolution proof.
3. A complete build dependency lock and exact CMake/RPATH configuration.
4. Pinned provenance for the RKLLM artifact and Alan LFS assets.
5. A tokenizer-aware conversation budget for the 4096-token RKLLM context.
6. A test bootstrap that installs `pytest`, or a documented dependency-free
   runner.

Until those gaps are closed, this branch is evidence for the known-working
pilot—not a promotion candidate.
