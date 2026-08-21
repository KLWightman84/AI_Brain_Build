#!/usr/bin/env bash
# Transactional Qwen3.5 native-tool contract repair.
# Aligns the prompt with Qwen3.5's <function>/<parameter> syntax while retaining
# backward-compatible parsing of the older JSON-in-<tool_call> form.
set -Eeuo pipefail
umask 077

readonly APP='/srv/aibrain/production/apps/AI_Brain_Build'
readonly SERVICE="$APP/src/aibrain_rkllm/service.py"
readonly TESTS="$APP/tests/test_service.py"
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
BACKUP_DIR="$BACKUP_ROOT/rkllm-qwen35-native-contract-$STAMP"
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

old_instructions = '''def _tool_instructions(tools: list[dict[str, object]]) -> str:
    """Render the Qwen tool-call contract without granting any new capability."""
    if not tools:
        return ""
    schemas = []
    for tool in tools:
        schemas.append(
            {
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool["description"],
                    "parameters": tool["parameters"],
                },
            }
        )
    return (
        "# Tools\\n\\n"
        "You may call only a listed function when it is needed. Reply with no prose "
        "when calling a function. Each call must be exactly one JSON object inside "
        f"{_TOOL_CALL_OPEN} and {_TOOL_CALL_CLOSE}: "
        '{"name":"function name","arguments":{}}.\\n\\n'
        "<tools>\\n"
        f"{json.dumps(schemas, separators=(',', ':'), ensure_ascii=False)}\\n"
        "</tools>"
    )
'''

new_instructions = '''def _tool_instructions(tools: list[dict[str, object]]) -> str:
    """Render the Qwen3.5 native function/parameter tool-call contract."""
    if not tools:
        return ""
    schemas = []
    for tool in tools:
        schemas.append(
            {
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool["description"],
                    "parameters": tool["parameters"],
                },
            }
        )
    schema_text = "\\n".join(
        json.dumps(schema, separators=(",", ":"), ensure_ascii=False) for schema in schemas
    )
    return (
        "# Tools\\n\\n"
        "You may call only a listed function when it is needed. Function names are not quoted. "
        "When calling a function, reply with no prose and no suffix. Use this Qwen3.5 format:\\n"
        "<tool_call>\\n"
        "<function=FUNCTION_NAME>\\n"
        "<parameter=PARAMETER_NAME>\\nVALUE\\n</parameter>\\n"
        "</function>\\n"
        "</tool_call>\\n"
        "For a function with no parameters, leave the function body empty between the function tags.\\n\\n"
        "<tools>\\n"
        f"{schema_text}\\n"
        "</tools>"
    )
'''

if text.count(old_instructions) != 1:
    raise SystemExit('ERROR: Qwen tool-instruction anchor mismatch')
text = text.replace(old_instructions, new_instructions, 1)

old_parser = '''def _parse_qwen_tool_calls(text: str, tools: list[dict[str, object]]) -> list[dict[str, object]] | None:
    """Return validated Qwen tags, or None for ordinary assistant text.

    A malformed/unknown tag is deliberately ordinary text, never an executable call.
    """
    if _TOOL_CALL_OPEN not in text:
        return None
    allowed = {tool["name"] for tool in tools}
    calls: list[dict[str, object]] = []
    offset = 0
    while True:
        start = text.find(_TOOL_CALL_OPEN, offset)
        if start < 0:
            break
        end = text.find(_TOOL_CALL_CLOSE, start + len(_TOOL_CALL_OPEN))
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
    return calls or None
'''

new_parser = '''def _parse_qwen_tool_calls(text: str, tools: list[dict[str, object]]) -> list[dict[str, object]] | None:
    """Return validated Qwen3.5/native or legacy Qwen tool tags.

    Native Qwen3.5 calls use <function=name> with zero or more
    <parameter=name>value</parameter> entries. The older JSON envelope remains
    accepted for backward compatibility. Unknown or malformed calls are text,
    never executable tool calls.
    """
    if _TOOL_CALL_OPEN not in text:
        return None
    allowed = {tool["name"]: tool for tool in tools}
    calls: list[dict[str, object]] = []
    offset = 0
    while True:
        start = text.find(_TOOL_CALL_OPEN, offset)
        if start < 0:
            break
        end = text.find(_TOOL_CALL_CLOSE, start + len(_TOOL_CALL_OPEN))
        closed = end >= 0
        if not closed:
            # RKLLM has been observed to stop after a complete tool payload.
            # Clean EOF may stand in for the missing outer closing tag only;
            # the inner payload must still parse completely below.
            end = len(text)
        raw = text[start + len(_TOOL_CALL_OPEN):end].strip()

        if raw.startswith("<function="):
            name_end = raw.find(">", len("<function="))
            if name_end < 0 or not raw.endswith("</function>"):
                return None
            name = raw[len("<function="):name_end].strip()
            if name not in allowed:
                return None

            function_body = raw[name_end + 1:-len("</function>")]
            arguments: dict[str, object] = {}
            position = 0
            while True:
                while position < len(function_body) and function_body[position].isspace():
                    position += 1
                if position >= len(function_body):
                    break
                prefix = "<parameter="
                if not function_body.startswith(prefix, position):
                    return None
                parameter_end = function_body.find(">", position + len(prefix))
                if parameter_end < 0:
                    return None
                parameter_name = function_body[position + len(prefix):parameter_end].strip()
                if not parameter_name or parameter_name in arguments:
                    return None
                close_parameter = "</parameter>"
                value_end = function_body.find(close_parameter, parameter_end + 1)
                if value_end < 0:
                    return None
                value = function_body[parameter_end + 1:value_end]
                if value.startswith("\\n"):
                    value = value[1:]
                if value.endswith("\\n"):
                    value = value[:-1]
                arguments[parameter_name] = value
                position = value_end + len(close_parameter)

            parameters = allowed[name].get("parameters", {})
            if not isinstance(parameters, dict):
                return None
            properties = parameters.get("properties", {})
            if not isinstance(properties, dict):
                return None
            if any(parameter_name not in properties for parameter_name in arguments):
                return None
            required = parameters.get("required", [])
            if not isinstance(required, list) or any(not isinstance(item, str) for item in required):
                return None
            if any(item not in arguments for item in required):
                return None
            candidate = {"name": name, "arguments": arguments}
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
    return calls or None
'''

if text.count(old_parser) != 1:
    raise SystemExit('ERROR: Qwen parser anchor mismatch')
text = text.replace(old_parser, new_parser, 1)
path.write_text(text)
print('PASS: Qwen3.5 native tool contract applied')
PY
chmod "$SERVICE_MODE" "$SERVICE"
APPLIED=1

"$PYTHON" -m py_compile "$SERVICE"

# Run every existing service test. The legacy JSON tool-call test must continue to pass.
PYTHONPATH="$APP/src" "$PYTHON" - "$TESTS" <<'PY'
import runpy, sys
tests = runpy.run_path(sys.argv[1])
for name in sorted(key for key in tests if key.startswith("test_")):
    tests[name]()
    print(f"PASS {name}")
PY

# Additional strict parser checks for the Qwen3.5 native XML dialect.
PYTHONPATH="$APP/src" "$PYTHON" - <<'PY'
from aibrain_rkllm.service import _parse_qwen_tool_calls

maintenance = [{
    "name": "maintenance_inspect",
    "description": "Read-only maintenance inspection.",
    "parameters": {"type": "object", "properties": {}},
}]
expected_maintenance = [{"name": "maintenance_inspect", "arguments": {}}]

assert _parse_qwen_tool_calls(
    '<tool_call>\n<function=maintenance_inspect>\n</function>\n</tool_call>', maintenance
) == expected_maintenance
assert _parse_qwen_tool_calls(
    '<tool_call>\n<function=maintenance_inspect>\n</function>', maintenance
) == expected_maintenance

with_param = [{
    "name": "echo_value",
    "description": "Echo one value.",
    "parameters": {
        "type": "object",
        "properties": {"value": {"type": "string"}},
        "required": ["value"],
    },
}]
assert _parse_qwen_tool_calls(
    '<tool_call><function=echo_value><parameter=value>\nhello\n</parameter></function></tool_call>',
    with_param,
) == [{"name": "echo_value", "arguments": {"value": "hello"}}]

# Backward-compatible JSON form remains valid.
assert _parse_qwen_tool_calls(
    '<tool_call>{"name":"maintenance_inspect","arguments":{}}</tool_call>', maintenance
) == expected_maintenance

# Malformed or unauthorized native forms stay non-executable.
assert _parse_qwen_tool_calls(
    '<tool_call><function=shutdown></function></tool_call>', maintenance
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=maintenance_inspect"><\/function></tool_call>', maintenance
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=maintenance_inspect><parameter=extra>x</parameter></function></tool_call>', maintenance
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=echo_value></function></tool_call>', with_param
) is None
assert _parse_qwen_tool_calls(
    '<tool_call><function=echo_value><parameter=value>x</parameter><parameter=value>y</parameter></function></tool_call>',
    with_param,
) is None
print('PASS: Qwen3.5 native parser safety checks')
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
print('PASS: live Qwen3.5 Maintenance response converted to OpenAI tool_calls')
PY

NEW_SHA=$(sha256sum "$SERVICE" | awk '{print $1}')
APPLIED=0
trap - ERR EXIT
printf '%s\n' 'PASS: Qwen3.5 native tool contract repair installed.'
printf 'service.py SHA-256: %s\n' "$NEW_SHA"
printf 'Backup: %s\n' "$BACKUP_DIR"
printf '%s\n' 'Next WebUI check: Run a maintenance inspection on yourself'
