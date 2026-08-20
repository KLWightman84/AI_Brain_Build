#!/usr/bin/env bash
# Source-locked Stage 1 installer: RKLLM finish_reason reporting.
set -euo pipefail

APP=/srv/aibrain/production/apps/AI_Brain_Build
SERVICE="$APP/src/aibrain_rkllm/service.py"
TESTS="$APP/tests/test_service.py"
PYTHON=/srv/aibrain/production/runtime/rkllm-venv/bin/python3
BACKUPS=/srv/aibrain/test/backups
SERVICE_NAME=aibrain-rkllm.service

# These are the verified, pre-installation files currently on the Pi.
EXPECTED_SERVICE_SHA=6bb2338b4cf1118611053ac6a4c2c9d92ee2327ca02c0c3849d118dbb37278de
EXPECTED_TESTS_SHA=db47fb02f432a9c68cba685c19ca717b1bf4e006603fb93f905f52c7f1b7d8ae

# Immutable payload commit: do not replace this with a branch name.
PAYLOAD_COMMIT=88b820c40dee4f794794a8d69cc2cdd92c88c81e
PAYLOAD_BASE="https://raw.githubusercontent.com/KLWightman84/AI_Brain_Build/$PAYLOAD_COMMIT/deployment/rkllm-stage1-finish-reason/payload"

TMPDIR=
BACKUP_DIR=
APPLIED=0

die() {
    echo "ERROR: $*" >&2
    exit 1
}

rollback_if_needed() {
    local status=$?
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$APPLIED" -eq 1 ]; then
        echo "Stage 1 failed; restoring the pre-installation source."
        cp "$BACKUP_DIR/service.py" "$SERVICE"
        cp "$BACKUP_DIR/test_service.py" "$TESTS"
        systemctl --user restart "$SERVICE_NAME" || true
    fi
    [ -z "$TMPDIR" ] || rm -rf "$TMPDIR"
    exit "$status"
}
trap rollback_if_needed EXIT

[ -x "$PYTHON" ] || die "Python runtime not found: $PYTHON"
[ -f "$SERVICE" ] || die "Service source not found: $SERVICE"
[ -f "$TESTS" ] || die "Test source not found: $TESTS"

current_service_sha=$(sha256sum "$SERVICE" | awk '{print $1}')
current_tests_sha=$(sha256sum "$TESTS" | awk '{print $1}')
[ "$current_service_sha" = "$EXPECTED_SERVICE_SHA" ] || die "Unexpected service.py hash; no files changed."
[ "$current_tests_sha" = "$EXPECTED_TESTS_SHA" ] || die "Unexpected test_service.py hash; no files changed."

TMPDIR=$(mktemp -d /tmp/rkllm-stage1.XXXXXX)
curl --fail --location --silent --show-error     "$PAYLOAD_BASE/service.py" -o "$TMPDIR/service.py"
curl --fail --location --silent --show-error     "$PAYLOAD_BASE/test_service.py" -o "$TMPDIR/test_service.py"

mkdir -p "$BACKUPS"
BACKUP_DIR="$BACKUPS/rkllm-stage1-preinstall-$(date +%Y%m%d-%H%M%S)"
mkdir "$BACKUP_DIR"
cp -a "$SERVICE" "$BACKUP_DIR/service.py"
cp -a "$TESTS" "$BACKUP_DIR/test_service.py"

cp "$TMPDIR/service.py" "$SERVICE"
cp "$TMPDIR/test_service.py" "$TESTS"
APPLIED=1

"$PYTHON" -m py_compile "$SERVICE" "$TESTS"
"$PYTHON" - "$TESTS" <<'PY'
import runpy
import sys

tests = runpy.run_path(sys.argv[1])
for name in sorted(key for key in tests if key.startswith("test_")):
    tests[name]()
    print(f"PASS {name}")
PY

systemctl --user restart "$SERVICE_NAME"
for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8081/healthz >/dev/null; then
        break
    fi
    sleep 1
done
curl -fsS http://127.0.0.1:8081/healthz >/dev/null || die "RKLLM service did not become healthy."

context_response=$(curl --fail --silent --show-error --max-time 90     -H 'Content-Type: application/json'     -d '{"model":"rkllm","max_tokens":16,"messages":[{"role":"system","content":"For this diagnostic, reply with exactly CONTEXT-OK and nothing else."},{"role":"user","content":"Respond now."}]}'     http://127.0.0.1:8081/v1/chat/completions)
"$PYTHON" - "$context_response" <<'PY'
import json
import sys

choice = json.loads(sys.argv[1])["choices"][0]
assert choice["message"]["content"] == "CONTEXT-OK", choice
assert choice["finish_reason"] == "stop", choice
PY

length_response=$(curl --fail --silent --show-error --max-time 120     -H 'Content-Type: application/json'     -d '{"model":"rkllm","max_tokens":8,"messages":[{"role":"system","content":"Give a detailed answer; do not use a one-word reply."},{"role":"user","content":"Explain how a blacksmith prepares iron before forging it."}]}'     http://127.0.0.1:8081/v1/chat/completions)
"$PYTHON" - "$length_response" <<'PY'
import json
import sys

choice = json.loads(sys.argv[1])["choices"][0]
assert choice["message"]["content"].strip(), choice
assert choice["finish_reason"] == "length", choice
PY

echo "Stage 1 installed and verified."
echo "Backup: $BACKUP_DIR"
