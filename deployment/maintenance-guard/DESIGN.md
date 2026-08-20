# Maintenance Guard design review

## Decision

Build a separate, user-owned maintenance control plane now. Do **not** add a
general command-execution tool to DAWN in the current pilot.

The guard can collect bounded evidence and produce an immutable, hash-locked
release command. It cannot apply the release. This preserves the established
Terra → Codex → immutable GitHub artifact → owner-run command workflow.

## Documented guardrails carried forward

| Documented rule | Enforced behavior |
| --- | --- |
| Preserve known-good state | No mutation, restart, installation, or configuration write is available. |
| One major variable at a time | Every release request represents one `repair`, `upgrade`, or `pilot`. |
| Do not repeat failed paths blindly | The AI contract requires evidence and a stated rationale. |
| Record BEFORE/CHANGE/TEST/RESULT/DECISION/COMMANDS/FILES | Required workflow fields in the AI tool contract and release verification list. |
| Durable evidence, not chat-only claims | `inspect` and `plan` create JSON artifacts suitable for review and retention. |
| Human approval for consequential work | The rendered command is not executable through this program or by the AI. |

## Current-system comparison

The historical references describe a root/system-service DAWN installation on
`/opt`, sometimes externally bound on ports 3000/8081, with the smaller 0.8B
model. That is evidence, not the active target.

The current pilot instead uses:

- `aibrain-rkllm.service` as a **user** service on `127.0.0.1:8081`;
- `dawn-stage3-webui-tts.service` as a **user** service on
  `127.0.0.1:3000`;
- the 4B RKLLM artifact with a 4096-token limit;
- a separate test/build tree and immutable GitHub deployment artifacts;
- DAWN tool mode not yet promoted as a trusted production-control surface.

The guard therefore defaults to only those two user services and does not read
the historical `/opt` configuration, system units, audio stack, MQTT, models,
or secrets.

## Explicit non-goals

- No arbitrary shell execution or command strings from the model.
- No `sudo`, package changes, network exposure, reboot, shutdown, or service
  restart.
- No source/config/model/secrets inspection or modification.
- No direct GitHub write, branch creation, or download from model-provided URLs.
- No claim that a release is safe merely because it has a hash.

## Future DAWN integration gate

A native DAWN tool or MCP adapter may call only `inspect` and `plan`, never an
apply action. That integration is deferred until DAWN tool orchestration has a
separate accepted build, owner authentication, audit trail, and prompt-injection
review. The maintenance guard is useful without it: an operator can provide its
JSON evidence to the AI and receive a reproducible pilot proposal.
