#!/usr/bin/env bash
# Diagnostic wrapper for the native tool budget v2 pilot.
# Repairs the known current_label ordering defect and preserves HTTP error bodies
# from the live maintenance tool-call probe. The upstream installer still owns
# backup, rollback, tests, restart, health, and loopback verification.
set -euo pipefail

readonly UPSTREAM_URL='https://raw.githubusercontent.com/KLWightman84/AI_Brain_Build/618d726890889e5996bf62b59335a2ad63136f77/deployment/rkllm-native-tool-budget-v2/run.sh'
readonly UPSTREAM_SHA='f5985b0182e19cc10d123d71a7eee94c2e66a03ab093241e1a6938703993a38e'
readonly ORIGINAL='/tmp/rkllm-native-tool-budget-v2-original.sh'
readonly DIAGNOSTIC='/tmp/rkllm-native-tool-budget-v2-diagnostic-inner.sh'

curl --fail --location --silent --show-error "$UPSTREAM_URL" -o "$ORIGINAL"
printf '%s  %s\n' "$UPSTREAM_SHA" "$ORIGINAL" | sha256sum -c -

python3 - "$ORIGINAL" "$DIAGNOSTIC" <<'PY'
from pathlib import Path
import base64
import re
import sys

source_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
installer = source_path.read_text()

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
if service.count(broken) != 1:
    raise SystemExit('ERROR: current_label ordering anchor mismatch')
service = service.replace(broken, fixed)
new_payload = base64.b64encode(service.encode('utf-8')).decode('ascii')
installer = installer[:match.start('payload')] + new_payload + installer[match.end('payload'):]

old_curl = 'curl --fail --silent --show-error --max-time 120'
new_curl = 'curl --silent --show-error --max-time 120'
count = installer.count(old_curl)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one live probe curl option sequence, found {count}')
installer = installer.replace(old_curl, new_curl, 1)

old_py = '''body = json.loads(sys.argv[1])\nchoice = body["choices"][0]\n'''
new_py = '''body = json.loads(sys.argv[1])\nif "error" in body:\n    print("LIVE_PROBE_ERROR:", json.dumps(body, separators=(",", ":")), file=sys.stderr)\n    raise SystemExit(1)\nchoice = body["choices"][0]\n'''
if installer.count(old_py) != 1:
    raise SystemExit('ERROR: live probe JSON anchor mismatch')
installer = installer.replace(old_py, new_py, 1)

out_path.write_text(installer)
print('PASS: diagnostic payload prepared')
PY

chmod 700 "$DIAGNOSTIC"
exec bash "$DIAGNOSTIC"
