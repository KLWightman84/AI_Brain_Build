#!/usr/bin/env bash
# Incremental compatibility repair for the observed Qwen3.5 RKLLM native form:
# <tool_call><function=NAME>{"arguments":{...}}</function>[</tool_call>]
# Keeps the existing canonical JSON form and all offered-tool/argument guards.
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
  fail "service.py identity differs from the restored repaired-v2 state: $actual"

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/rkllm-native-function-tag-$STAMP"
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
        try:
            candidate = json.loads(raw)
        except json.JSONDecodeError:
            return None
        if (
            not isinstance(candidate, dict)
            or not isinstance(candidate.get("name"), str)
            or candidate["name"] not in allowed
            or not isinstance(candidate.get("arguments"), dict)
        ):
            return None
        calls.append({"name": candidate["name"], "arguments": candidate["arguments"]})
        offset = end + len(_TOOL_CALL_CLOSE)
'''
new = '''        end = text.find(_TOOL_CALL_CLOSE, start + len(_TOOL_CALL_OPEN))
        closed = end >= 0
        if not closed:
            # Observed RKLLM output can end after a complete native tool payload
            # without emitting the literal </tool_call> delimiter.
            end = len(text)
        raw = text[start + len(_TOOL_CALL_OPEN):end].strip()

        if raw.startswith("<function="):
            # Observed Qwen3.5 native form:
            # <function=maintenance_inspect>{"arguments":{}}</function>
            name_end = raw.find(">", len("<function="))
            if name_end < 0 or not raw.endswith("</function>"):
                return None
            name = raw[len("<function="):name_end].strip()
            payload_text = raw[name_end + 1:-len("</function>")].strip()
            try:
                payload = json.loads(payload_text)
            except json.JSONDecodeError:
                return None
            if (
                name not in allowed
                or not isinstance(payload, dict)
                or set(payload) != {"arguments"}
                or not isinstance(payload.get("arguments"), dict)
            ):
                return None
            candidate = {"name": name, "arguments": payload["arguments"]}
        else:
            try:
                candidate = json.loads(raw)
            except json.JSONDecodeError:
                return None
            if (
                not isinstance(candidate, dict)
                or not isinstance(candidate.get("name"), str)
                or candidate["name"] not in allowed
                or not isinstance(candidate.get("arguments"), dict)
            ):
                return None

        calls.append({"name": candidate["name"], "arguments": candidate["arguments"]})
        if not closed:
            break
        offset = end + len(_TOOL_CALL_CLOSE)
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one strict parser block, found {count}')
path.write_text(text.replace(old, new, 1))
print('PASS: parser accepts canonical JSON and observed Qwen <function=...> form')
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

# Existing canonical format, with and without the outer closing tag.
assert _parse_qwen_tool_calls(
    '<tool_call>{"name":"maintenance_inspect","arguments":{}}</tool_call>', tools
) == expected
assert _parse_qwen_tool_calls(
    '<tool_call>\n{"name":"maintenance_inspect","arguments":{}}', tools
) == expected

# Exact native form observed from the live Qwen3.5 RKLLM runtime.
assert _parse_qwen_tool_calls(
    '<tool_call>\n<function=maintenance_inspect>{"arguments":{}}</function>', tools
) == expected
assert _parse_qwen_tool_calls(
    '<tool_call><function=maintenance_inspect>{"arguments":{}}</function></tool_call>', tools
) == expected

# Fail closed for malformed/unoffered variants.
assert _parse_qwen_tool_calls(
    '<tool_call><function=shutdown>{"arguments":{}}</function>', tools
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=maintenance_inspect>{"arguments":{}}', tools
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=maintenance_inspect>{"arguments":"bad"}</function>', tools
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=maintenance_inspect>{"arguments":{},"extra":1}</function>', tools
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=maintenance_inspect>{"arguments":{}}</function> trailing prose', tools
) is None
print('PASS: native function-tag parser safety checks')
PY

systemctl --user restart "$SERVICE_NAME"
wait_for_health || fail 'RKLLM service did not become healthy after restart'
curl -fsS --max-time 5 "$STATUS_URL" | grep -F '"max_context_length":4096' >/dev/null || \
  fail 'RKLLM DAWN context endpoint did not report 4096'

response=$(curl --silent --show-error --max-time 120 \
  -H 'Content-Type: application/json' \
  -d '{"model":"rkllm","max_tokens":96,"messages":[{"role":"system","content":"Call the offered maintenance_inspect function. Return no prose."},{"role":"user","content":"Run a maintenance inspection on yourself."}],"tools":[{"type":"function","function":{"name":"maintenance_inspect","description":"Report a concise read-only maintenance inspection for this DAWN host.","parameters":{"type":"object","properties":{}}}}]}' \
  http://127.0.0.1:8081/v1/chat/completions)

printf 'LIVE_RESPONSE=%s\n' "$response"
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
printf '%s\n' 'PASS: observed Qwen native function-tag compatibility repair installed.'
printf 'service.py SHA-256: %s\n' "$NEW_SHA"
printf 'Backup: %s\n' "$BACKUP_DIR"
printf '%s\n' 'Next WebUI check: Run a maintenance inspection on yourself'
