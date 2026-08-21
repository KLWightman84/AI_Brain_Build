# DAWN read-only maintenance inspection pilot

This pilot adds one native DAWN tool: `maintenance_inspect`.

It reports local LLM context availability, `/srv/aibrain` filesystem space,
memory, and one-minute load. It has no parameters and is available to local and
remote sessions. Its result explicitly states that it cannot run commands,
restart services, change configuration, install packages, change models, access
secrets, or modify files.

The existing `/srv/aibrain/production/maintenance/bin/aibrain-maintenance`
guard remains the owner-operated control plane for inspection evidence and
rendering approved deployment commands. This native DAWN tool does not invoke
that launcher because DAWN's coding harness prohibits process management.

## Installer behavior

`run.sh` verifies the exact source identities captured on 2026-08-21 before
editing. It creates timestamped backups of the two changed source files and the
DAWN executable, compiles the existing TTS/WebUI build, restarts only the DAWN
user service, and verifies the service, loopback WebUI binding, tool registration
log, and existing RKLLM health endpoint. Any failure after source application
restores the backed-up source and executable, then restarts the service.

It does not touch RKLLM, its service, the WebUI persona, the active TOML config,
or the maintenance policy.
