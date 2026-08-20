#!/usr/bin/env bash
# Temporary source-locked callback diagnostic. Always restores the live adapter.
set -euo pipefail

APP=/srv/aibrain/production/apps/AI_Brain_Build
SERVICE="$APP/src/aibrain_rkllm/service.py"
TESTS="$APP/tests/test_service.py"
PYTHON=/srv/aibrain/production/runtime/rkllm-venv/bin/python3
BACKUPS=/srv/aibrain/test/backups
LOGS=/srv/aibrain/test/logs
SERVICE_NAME=aibrain-rkllm.service
EXPECTED_SERVICE_SHA=6bb2338b4cf1118611053ac6a4c2c9d92ee2327ca02c0c3849d118dbb37278de
EXPECTED_TESTS_SHA=db47fb02f432a9c68cba685c19ca717b1bf4e006603fb93f905f52c7f1b7d8ae
PAYLOAD_COMMIT=cc699be104296f0bc46801afb1191030148f33b3
PAYLOAD_URL="https://raw.githubusercontent.com/KLWightman84/AI_Brain_Build/$PAYLOAD_COMMIT/deployment/rkllm-finish-reason-diagnostic/payload/service.py"

TMPDIR=
BACKUP=
APPLIED=0
LOG=

die() {
    echo "ERROR: $*" >&2
    exit 1
}

wait_for_health() {
    for _ in $(seq 1 30); do
        if curl -fsS http://127.0.0.1:8081/healthz >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

restore() {
    cp "$BACKUP" "$SERVICE"
    systemctl --user restart "$SERVICE_NAME"
    wait_for_health
}

cleanup() {
    local status=$?
    trap - EXIT
    if [ "$APPLIED" -eq 1 ]; then
        echo "Restoring the verified RKLLM adapter."
        restore || status=1
    fi
    [ -z "$TMPDIR" ] || rm -rf "$TMPDIR"
    exit "$status"
}
trap cleanup EXIT

[ -x "$PYTHON" ] || die "Python runtime not found: $PYTHON"
[ "$(sha256sum "$SERVICE" | awk '{print $1}')" = "$EXPECTED_SERVICE_SHA" ] ||
    die "Unexpected service.py hash; no files changed."
[ "$(sha256sum "$TESTS" | awk '{print $1}')" = "$EXPECTED_TESTS_SHA" ] ||
    die "Unexpected test_service.py hash; no files changed."

TMPDIR=$(mktemp -d /tmp/rkllm-diag.XXXXXX)
curl --fail --location --silent --show-error "$PAYLOAD_URL" -o "$TMPDIR/service.py"

mkdir -p "$BACKUPS" "$LOGS"
BACKUP="$BACKUPS/rkllm-finish-reason-diagnostic-pre-$(date +%Y%m%d-%H%M%S).py"
LOG="$LOGS/rkllm-finish-reason-diagnostic-$(date +%Y%m%d-%H%M%S).jsonl"
cp -a "$SERVICE" "$BACKUP"
cp "$TMPDIR/service.py" "$SERVICE"
APPLIED=1

"$PYTHON" -m py_compile "$SERVICE"
"$PYTHON" - "$TESTS" <<'PY'
import runpy
import sys

tests = runpy.run_path(sys.argv[1])
for name in sorted(key for key in tests if key.startswith("test_")):
    tests[name]()
PY

systemctl --user restart "$SERVICE_NAME"
wait_for_health || die "Temporary diagnostic service did not become healthy."

probe() {
    local label=$1
    local limit=$2
    local instruction=$3
    local message=$4
    local response diagnostics

    response=$(curl --fail --silent --show-error --max-time 120         -H 'Content-Type: application/json'         -d "{"model":"rkllm","max_tokens":$limit,"messages":[{"role":"system","content":"$instruction"},{"role":"user","content":"$message"}]}"         http://127.0.0.1:8081/v1/chat/completions)
    diagnostics=$(curl --fail --silent --show-error         http://127.0.0.1:8081/v1/dawn/last-run-diagnostics)

    "$PYTHON" - "$label" "$limit" "$response" "$diagnostics" <<'PY' | tee -a "$LOG"
import json
import sys

label, requested, response_raw, diagnostic_raw = sys.argv[1:]
choice = json.loads(response_raw)["choices"][0]
events = json.loads(diagnostic_raw)["events"]
if label == "control":
    assert choice["message"]["content"] == "CONTEXT-OK", choice

nonterminal = [event for event in events if event["state"] in (0, 1)]
summary = {
    "label": label,
    "requested_max_tokens": int(requested),
    "response_finish_reason": choice["finish_reason"],
    "callback_events": len(events),
    "nonterminal_events": len(nonterminal),
    "states": [event["state"] for event in events],
    "token_ids": [event["token_id"] for event in nonterminal],
    "text_event_count": sum(event["has_text"] for event in events),
    "text_bytes": sum(event["text_bytes"] for event in events),
    "perf_generate_tokens": [event["perf_generate_tokens"] for event in events],
}
print(json.dumps(summary, separators=(",", ":")))
PY
}

probe control 16     'For this diagnostic, reply with exactly CONTEXT-OK and nothing else.'     'Respond now.'
probe forced-1 1 'Give a detailed answer; do not use a one-word reply.'     'Explain how a blacksmith prepares iron before forging it.'
probe forced-2 2 'Give a detailed answer; do not use a one-word reply.'     'Explain how a blacksmith prepares iron before forging it.'
probe forced-3 3 'Give a detailed answer; do not use a one-word reply.'     'Explain how a blacksmith prepares iron before forging it.'
probe forced-8 8 'Give a detailed answer; do not use a one-word reply.'     'Explain how a blacksmith prepares iron before forging it.'

echo "Diagnostic metadata saved to: $LOG"
