#!/usr/bin/env bash
# Repair wrapper v2 for native tool budget pilot.
# Fixes the known current_label ordering defect and the malformed live probe JSON,
# while preserving HTTP error bodies for any later failure. The original installer
# still owns backup, rollback, tests, restart, health and loopback verification.
set -euo pipefail

readonly UPSTREAM_URL='https://raw.githubusercontent.com/KLWightman84/AI_Brain_Build/618d726890889e5996bf62b59335a2ad63136f77/deployment/rkllm-native-tool-budget-v2/run.sh'
readonly UPSTREAM_SHA='f5985b0182e19cc10d123d71a7eee94c2e66a03ab093241e1a6938703993a38e'
readonly ORIGINAL='/tmp/rkllm-native-tool-budget-v2-original.sh'
readonly REPAIRED='/tmp/rkllm-native-tool-budget-v2-fixed-v2-inner.sh'

curl --fail --location --silent --show-error "$UPSTREAM_URL" -o "$ORIGINAL"
printf '%s  %s\n' "$UPSTREAM_SHA" "$ORIGINAL" | sha256sum -c -

python3 - "$ORIGINAL" "$REPAIRED" <<'PY'
from pathlib import Path
import base64
import json
import re
import sys

source_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
installer = source_path.read_text()

# 1. Repair embedded service.py current_label ordering.
match = re.search(
    r'base64 -d >"\$SERVICE" <<\'SERVICE_PAYLOAD\'\n(?P<payload>[A-Za-z0-9+/=\n]+)\nSERVICE_PAYLOAD',
    installer,
)
if match is None:
    raise SystemExit('ERROR: could not locate embedded SERVICE_PAYLOAD')
encoded = ''.join(match.group('payload').split())
service = base64.b64decode(encoded).decode('utf-8')
broken = '''    current_role, current_text = normalized[current_index]\n    projected_tools = _project_tools(\n        tools or [], current_text, system_parts, current_label, token_budgeter, max_new_tokens\n    )\n    tool_text = _tool_instructions(projected_tools)\n    if tool_text:\n        system_parts.append(tool_text)\n    system_text = "\\n\\n".join(system_parts)\n    current_label = "CURRENT USER REQUEST" if current_role == "user" else "CURRENT TOOL RESULT"\n'''
fixed = '''    current_role, current_text = normalized[current_index]\n    current_label = "CURRENT USER REQUEST" if current_role == "user" else "CURRENT TOOL RESULT"\n    projected_tools = _project_tools(\n        tools or [], current_text, system_parts, current_label, token_budgeter, max_new_tokens\n    )\n    tool_text = _tool_instructions(projected_tools)\n    if tool_text:\n        system_parts.append(tool_text)\n    system_text = "\\n\\n".join(system_parts)\n'''
count = service.count(broken)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one broken current_label block, found {count}')
service = service.replace(broken, fixed)
new_payload = base64.b64encode(service.encode('utf-8')).decode('ascii')
installer = installer[:match.start('payload')] + new_payload + installer[match.end('payload'):]

# 2. Repair the live probe JSON: unrelated_planner function object is missing one closing brace.
bad_tail = '"description":"irrelevant"}}}}]}'
good_tail = '"description":"irrelevant"}}}}}]}'
count = installer.count(bad_tail)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one malformed live-probe JSON tail, found {count}')
installer = installer.replace(bad_tail, good_tail, 1)

# Validate the actual single-quoted -d payload after repair.
payload_match = re.search(r"-d '(?P<body>\{.*?\})' \\\n    http://127\.0\.0\.1:8081/v1/chat/completions", installer)
if payload_match is None:
    raise SystemExit('ERROR: could not locate repaired live-probe request body')
body = json.loads(payload_match.group('body'))
if not isinstance(body, dict) or len(body.get('tools', [])) != 2:
    raise SystemExit('ERROR: repaired live-probe JSON did not validate as expected')
print('PASS: live maintenance probe JSON validates')

# 3. Preserve JSON response bodies on HTTP errors for the next diagnostic stage.
old_curl = 'curl --fail --silent --show-error --max-time 120'
new_curl = 'curl --silent --show-error --max-time 120'
count = installer.count(old_curl)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one live probe curl option sequence, found {count}')
installer = installer.replace(old_curl, new_curl, 1)

old_py = '''body = json.loads(sys.argv[1])\nchoice = body["choices"][0]\n'''
new_py = '''body = json.loads(sys.argv[1])\nif "error" in body:\n    print("LIVE_PROBE_ERROR:", json.dumps(body, separators=(",", ":")), file=sys.stderr)\n    raise SystemExit(1)\nchoice = body["choices"][0]\n'''
if installer.count(old_py) != 1:
    raise SystemExit('ERROR: live probe JSON response anchor mismatch')
installer = installer.replace(old_py, new_py, 1)

out_path.write_text(installer)
print('PASS: repaired installer prepared')
PY

chmod 700 "$REPAIRED"
exec bash "$REPAIRED"
