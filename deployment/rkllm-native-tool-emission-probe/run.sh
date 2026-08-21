#!/usr/bin/env bash
# Read-only capability probe: asks the active Qwen/RKLLM model to emit one
# harmless Qwen-format tool call. It never invokes a DAWN tool or changes a
# service, source file, model, configuration, or conversation.
set -Eeuo pipefail
umask 077

CAPTURES=/srv/aibrain/test/captures
STAMP=$(date +%Y%m%d-%H%M%S)
STAGE=$(mktemp -d "$CAPTURES/.rkllm-native-tool-emission.XXXXXX")
ARCHIVE="$CAPTURES/rkllm-native-tool-emission-probe-$STAMP.tar.gz"
ENDPOINT=http://127.0.0.1:8081/v1/chat/completions

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$CAPTURES"

cat >"$STAGE/request.json" <<'JSON'
{
  "model": "rkllm",
  "max_tokens": 96,
  "stream": false,
  "tools": [{
    "type": "function",
    "function": {
      "name": "protocol_probe",
      "description": "Harmless protocol test. It has no side effects.",
      "parameters": {"type": "object", "properties": {}, "additionalProperties": false}
    }
  }],
  "messages": [
    {
      "role": "system",
      "content": "# Tools\n\nYou may call one or more functions to assist with the user query.\n\nYou are provided with function signatures within <tools></tools> XML tags:\n<tools>\n{\"type\":\"function\",\"function\":{\"name\":\"protocol_probe\",\"description\":\"Harmless protocol test. It has no side effects.\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}}\n</tools>\n\nFor each function call, return a JSON object with function name and arguments within <tool_call></tool_call> XML tags. The arguments value must be an object, not a string. Return exactly one call and no explanatory prose."
    },
    {"role": "user", "content": "Call protocol_probe now."}
  ]
}
JSON

curl --fail --silent --show-error --max-time 120 \
  -H 'Content-Type: application/json' \
  --data-binary @"$STAGE/request.json" \
  "$ENDPOINT" >"$STAGE/response.json" || fail "RKLLM native-tool emission probe request failed"

python3 - "$STAGE/response.json" "$STAGE/result.txt" <<'PY'
import json
from pathlib import Path
import sys

response = json.loads(Path(sys.argv[1]).read_text())
content = response["choices"][0]["message"]["content"]
Path(sys.argv[2]).write_text(
    "qwen_tool_tag_detected=" + str("<tool_call>" in content and "</tool_call>" in content).lower() + "\n"
    + "response_content:\n" + content + "\n"
)
PY

if grep -RInE \
  '(gho_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|DAWN-[A-Z0-9-]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' \
  "$STAGE" >/dev/null; then
  fail "Sensitive-value scan failed; probe archive was not created"
fi

tar -C "$STAGE" -czf "$ARCHIVE" .
printf '%s\n' 'PASS: RKLLM native-tool emission probe completed.'
printf 'Archive: %s\n' "$ARCHIVE"
printf 'Archive SHA-256: %s\n' "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf 'Result: tar -xOzf %s ./result.txt\n' "$ARCHIVE"
