#!/usr/bin/env bash
# Repair wrapper for 618d726: initialize current_label before tool projection.
# The original v2 installer remains immutable; this wrapper verifies it, repairs
# only the embedded service.py ordering defect, then executes its full
# transactional test/restart/health/tool-call probe sequence.
set -euo pipefail

readonly UPSTREAM_URL='https://raw.githubusercontent.com/KLWightman84/AI_Brain_Build/618d726890889e5996bf62b59335a2ad63136f77/deployment/rkllm-native-tool-budget-v2/run.sh'
readonly UPSTREAM_SHA='f5985b0182e19cc10d123d71a7eee94c2e66a03ab093241e1a6938703993a38e'
readonly ORIGINAL='/tmp/rkllm-native-tool-budget-v2-original.sh'
readonly REPAIRED='/tmp/rkllm-native-tool-budget-v2-repaired.sh'

curl --fail --location --silent --show-error "$UPSTREAM_URL" -o "$ORIGINAL"
printf '%s  %s\n' "$UPSTREAM_SHA" "$ORIGINAL" | sha256sum -c -

python3 - "$ORIGINAL" "$REPAIRED" <<'PY'
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

broken = '''    current_role, current_text = normalized[current_index]
    projected_tools = _project_tools(
        tools or [], current_text, system_parts, current_label, token_budgeter, max_new_tokens
    )
    tool_text = _tool_instructions(projected_tools)
    if tool_text:
        system_parts.append(tool_text)
    system_text = "\\n\\n".join(system_parts)
    current_label = "CURRENT USER REQUEST" if current_role == "user" else "CURRENT TOOL RESULT"
'''

fixed = '''    current_role, current_text = normalized[current_index]
    current_label = "CURRENT USER REQUEST" if current_role == "user" else "CURRENT TOOL RESULT"
    projected_tools = _project_tools(
        tools or [], current_text, system_parts, current_label, token_budgeter, max_new_tokens
    )
    tool_text = _tool_instructions(projected_tools)
    if tool_text:
        system_parts.append(tool_text)
    system_text = "\\n\\n".join(system_parts)
'''

count = service.count(broken)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one broken ordering block, found {count}')

service = service.replace(broken, fixed)
new_payload = base64.b64encode(service.encode('utf-8')).decode('ascii')
repaired = installer[:match.start('payload')] + new_payload + installer[match.end('payload'):]
out_path.write_text(repaired)
print('PASS: repaired embedded service.py current_label ordering')
PY

chmod 700 "$REPAIRED"
exec bash "$REPAIRED"
