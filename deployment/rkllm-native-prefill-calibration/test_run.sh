#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$ROOT/run.sh"
STAGING="$ROOT/staging/src/aibrain_rkllm/service.py"

bash -n "$RUN"
grep -Fq "readonly SOURCE_SHA='6bb2338b4cf1118611053ac6a4c2c9d92ee2327ca02c0c3849d118dbb37278de'" "$RUN"
grep -Fq "native RKLLM prefill telemetry" "$RUN"
grep -Fq 'http://127.0.0.1:8081/v1/chat/completions' "$RUN"
grep -Fq 'restore_source' "$RUN"
grep -Fq 'candidate only; no trimming behavior was retained' "$RUN"
if grep -Eq '(sudo|apt |pip install|git (add|commit|push))' "$RUN"; then
    echo 'FAIL: calibration must not alter system packages or source control state' >&2
    exit 1
fi

embedded=$(mktemp)
trap 'rm -f -- "$embedded"' EXIT
awk '
    /<<'"'"'CALIBRATED_SERVICE'"'"'/ { capture = 1; next }
    capture && /^CALIBRATED_SERVICE$/ { exit }
    capture { print }
' "$RUN" | base64 -d >"$embedded"
cmp -s "$embedded" "$STAGING"

echo 'PASS: native prefill calibration static checks completed.'
