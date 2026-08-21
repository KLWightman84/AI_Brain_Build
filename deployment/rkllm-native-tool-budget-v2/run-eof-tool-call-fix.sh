#!/usr/bin/env bash
# Incremental native-tool compatibility repair.
# Accept a final Qwen <tool_call> whose JSON reaches cleanly to end-of-output
# even when RKLLM omits the literal </tool_call> closing tag.
set -Eeuo pipefail
umask 077

readonly APP='/srv/aibrain/production/apps/AI_Brain_Build'
readonly SERVICE="$APP/src/aibrain_rkllm/service.py"
readonly PYTHON='/srv/aibrain/production/runtime/rkllm-venv/bin/python3'
readonly SERVICE_NAME='aibrain-rkllm.service'
readonly HEALTH_URL='http://127.0.0.1:8081/healthz'
readonly STATUS_URL='http://127.0.0.1:8081/v1/dawn/status'
readonly BACKUP_ROOT='/srv/aibrain/test/backups'
readonly EXPECTED_SERVICE_SHA='0e871a1196da84985b5193ed4608564321b808511ca92c755d2463347cf0465d'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

wait_for_health() {
  for _ in $(seq 1 45); do
    curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null && return 0
    sleep 1
  done
  return 1
}

actual=$(sha256sum "$SERVICE" | awk '{print $1}')
[[ "$actual" == "$EXPECTED_SERVICE_SHA" ]] || \
  fail "service.py identity differs from the installed repaired-v2 state: $actual"

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/rkllm-eof-tool-call-$STAMP"
mkdir -p "$BACKUP_DIR"
cp -a "$SERVICE" "$BACKUP_DIR/service.py"
SERVICE_MODE=$(stat -c '%a' "$SERVICE")
APPLIED=0

restore() {
  if [[ "$APPLIED" -eq 1 ]]; then
    printf '%s\n' 'Restoring RKLLM service.py from this installer backup.' >&2
    cp -a "$BACKUP_DIR/service.py" "$SERVICE"
    chmod "$SERVICE_MODE" "$SERVICE"
    systemctl --user restart "$SERVICE_NAME" || true
    wait_for_health || true
    APPLIED=0
  fi
}

rollback() {
  local code=$?
  trap - ERR EXIT
  restore
  exit "$code"
}
trap rollback ERR EXIT

python3 - "$SERVICE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''        end = text.find(_TOOL_CALL_CLOSE, start + len(_TOOL_CALL_OPEN))
        if end < 0:
            return None
        raw = text[start + len(_TOOL_CALL_OPEN):end].strip()
'''
new = '''        end = text.find(_TOOL_CALL_CLOSE, start + len(_TOOL_CALL_OPEN))
        if end < 0:
            # Qwen/RKLLM can terminate immediately after a complete tool-call JSON object.
            # Treat clean end-of-output as the final delimiter. json.loads() below still
            # requires the entire remaining tail to be valid JSON, so trailing prose,
            # malformed JSON, and additional unterminated calls remain non-executable.
            end = len(text)
        raw = text[start + len(_TOOL_CALL_OPEN):end].strip()
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one strict closing-tag parser block, found {count}')
path.write_text(text.replace(old, new, 1))
print('PASS: parser now permits only clean EOF-terminated final tool-call JSON')
PY
chmod "$SERVICE_MODE" "$SERVICE"
APPLIED=1

"$PYTHON" -m py_compile "$SERVICE"

PYTHONPATH="$APP/src" "$PYTHON" - <<'PY'
from aibrain_rkllm.service import _parse_qwen_tool_calls

tools = [{
    "name": "maintenance_inspect",
    "description": "Read-only maintenance inspection.",
    "parameters": {"type": "object", "properties": {}},
}]
expected = [{"name": "maintenance_inspect", "arguments": {}}]

assert _parse_qwen_tool_calls(
    '<tool_call>{"name":"maintenance_inspect","arguments":{}}</tool_call>', tools
) == expected
assert _parse_qwen_tool_calls(
    '<tool_call>\n{"name":"maintenance_inspect","arguments":{}}', tools
) == expected
assert _parse_qwen_tool_calls(
    '<tool_call>{"name":"maintenance_inspect","arguments":{}} trailing prose', tools
) is None
assert _parse_qwen_tool_calls(
    '<tool_call>{"name":"maintenance_inspect","arguments":', tools
) is None
assert _parse_qwen_tool_calls(
    '<tool_call>{"name":"shutdown","arguments":{}}', tools
) is None
assert _parse_qwen_tool_calls(
    '<tool_call>{"name":"maintenance_inspect","arguments":"not-an-object"}', tools
) is None
print('PASS: EOF compatibility parser safety checks')
PY

systemctl --user restart "$SERVICE_NAME"
wait_for_health || fail 'RKLLM service did not become healthy after restart'
curl -fsS --max-time 5 "$STATUS_URL" | grep -F '"max_context_length":4096' >/dev/null || \
  fail 'RKLLM DAWN context endpoint did not report 4096'

response=$(curl --silent --show-error --max-time 120 \
  -H 'Content-Type: application/json' \
  -d '{"model":"rkllm","max_tokens":96,"messages":[{"role":"system","content":"Call the offered maintenance_inspect function. Return no prose."},{"role":"user","content":"Run a maintenance inspection on yourself."}],"tools":[{"type":"function","function":{"name":"maintenance_inspect","description":"Report a concise read-only maintenance inspection for this DAWN host.","parameters":{"type":"object","properties":{}}}}]}' \
  http://127.0.0.1:8081/v1/chat/completions)

"$PYTHON" - "$response" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
if "error" in body:
    raise SystemExit(f'LIVE_PROBE_ERROR: {json.dumps(body, separators=(",", ":"))}')
choice = body["choices"][0]
calls = choice["message"].get("tool_calls", [])
assert choice["finish_reason"] == "tool_calls", choice
assert choice["message"].get("content") is None, choice
assert len(calls) == 1, calls
assert calls[0]["function"]["name"] == "maintenance_inspect", calls
assert calls[0]["function"]["arguments"] == "{}", calls
print('PASS: live RKLLM Maintenance response converted to OpenAI tool_calls')
PY

NEW_SHA=$(sha256sum "$SERVICE" | awk '{print $1}')
APPLIED=0
trap - ERR EXIT
printf '%s\n' 'PASS: EOF-terminated native tool-call compatibility repair installed.'
printf 'service.py SHA-256: %s\n' "$NEW_SHA"
printf 'Backup: %s\n' "$BACKUP_DIR"
printf '%s\n' 'Next WebUI check: Run a maintenance inspection on yourself'
