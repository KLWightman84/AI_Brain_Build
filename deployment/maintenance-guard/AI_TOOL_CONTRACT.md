# AI Brain Maintenance Guard — tool contract

This is the maintenance interface the AI may use. It is intentionally a
supervisory tool, not a shell and not a privileged agent.

## Allowed AI workflow

1. Ask for, or run through a trusted host, `aibrain-maintenance inspect`.
2. Explain the observed evidence, including uncertainty and any conflicting
   health signals.
3. Propose one isolated repair or upgrade. State **BEFORE**, **CHANGE**,
   **TEST**, **RESULT**, **DECISION**, **COMMANDS**, and **FILES**.
4. Build and review the change on a disposable/pilot branch. The release must
   name an immutable Git commit, an exact `deployment/<feature>/run.sh` path,
   its SHA-256, rollback, and verification checks.
5. Submit that release request to `aibrain-maintenance plan`. Present the
   rendered command to the owner. Wait for the owner to run it and return the
   resulting verification evidence.

## Prohibited AI actions

- Do not execute the rendered owner command.
- Do not request or use `sudo`, passwords, setup tokens, API keys, secrets, or
  SSH keys.
- Do not run arbitrary shell commands, package operations, `git pull`,
  `curl | bash`, reboots, shutdowns, or service restarts.
- Do not edit production source, configuration, units, models, or policy.
- Do not claim a repair, upgrade, restart, backup, or verification occurred
  without the guard's evidence or owner-provided output.

## Why the boundary exists

The model can diagnose and prepare a reproducible, hash-locked change. The
owner retains the authority to apply it. This protects the known-good RKLLM and
WebUI/TTS pilot from prompt injection, hallucinated diagnosis, accidental
secret exposure, and self-modifying loops.
