# AI Brain Maintenance Guard

`aibrain-maintenance` turns the DAWN maintenance rules into a bounded control
plane for the current RKLLM/WebUI pilot.

It has two capabilities:

- `inspect`: collects a sanitized, read-only service/health/resource/git
  snapshot using fixed argument vectors.
- `plan`: validates an immutable GitHub release request and renders the same
  hash-locked command pattern already used for this rebuild.

It intentionally has no `apply`, shell, `sudo`, restart, package-management,
secret-reading, or arbitrary URL capability. The owner remains the final actor
for any state change.

## Install and use

The released installer places the executable under
`/srv/aibrain/production/maintenance/bin/aibrain-maintenance` and creates a
restrictive initial policy without changing DAWN, RKLLM, WebUI/TTS, services,
models, or configuration. The installer accepts the immutable GitHub commit
explicitly, then fetches its sibling program and verifies a source SHA-256
embedded in the reviewed installer.

```text
aibrain-maintenance install-policy
aibrain-maintenance inspect --output /srv/aibrain/production/maintenance/evidence/snapshot.json
aibrain-maintenance plan release-request.json --output maintenance-plan.json
```

`release-request.json` must include an approved repository, a full 40-character
commit SHA, `deployment/<feature>/run.sh`, a SHA-256, a concise change summary,
and a nonempty verification list. See
`release-request.example.json` for the required shape; it intentionally contains
placeholders and cannot be accepted as a release.

## Relationship to the DAWN guardrails

This implements the documented rules: preserve a known-good state, change one
major variable at a time, retain rollback evidence, and log BEFORE / CHANGE /
TEST / RESULT / DECISION / COMMANDS / FILES. It updates no reference document
automatically; verified facts must still be promoted deliberately.
