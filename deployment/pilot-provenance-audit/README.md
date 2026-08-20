# Pilot Provenance Audit

This is an evidence-only Phase 6 capture for the verified Stage-3
WebUI/TTS/RKLLM pilot. It is not an installer, migration, repair tool, or
promotion mechanism.

## Safety contract

`run.sh` refuses to run unless both active user services are running. It does
not restart services, install packages, download assets, alter source/build
trees, write to GitHub, or read secrets, runtime databases, logs, cookies,
virtual environments, or process environments.

It writes a new timestamped, sanitized archive under
`/srv/aibrain/test/captures/`. The archive deliberately excludes model
binaries and records their paths, sizes, and hashes instead.

## Evidence collected

- DAWN/WebUI/Whisper source identity, tree manifests, selected accepted patches,
  and static frontend manifest.
- Piper phonemize source/build configuration; ONNX, eSpeak, header wiring; and
  environment-aware shared-library evidence for the active DAWN process.
- Active RKLLM, Whisper, and Alan model identities without copying model data.
- CMake cache/linkage, toolchain, and selected package inventory.
- RKLLM adapter revision, accepted local diff, and current test-bootstrap state.
- Relative-path checksums, a payload allowlist, and sensitive-value scanning.

## Result interpretation

The generated `report.md` marks every gate as `PASS` or `INCOMPLETE`.
`INCOMPLETE` is an expected and useful result where the current pilot lacks an
immutable origin, conversion lineage, or reproducible dependency definition.
No gate is inferred to pass merely because a service currently works.

Only an archive with a passing integrity manifest and secret scan is valid for
review. The pilot remains unpromoted until all provenance gates are closed.
