#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$ROOT/run.sh"

bash -n "$RUN"
grep -Fq 'candidate only; native RKLLM prefill telemetry calibration is still required' "$RUN"
grep -Fq 'python3 -m pip download' "$RUN"
grep -Fq '"$VENV/bin/python" -m pip install --no-index --no-deps "$WHEEL_PATH"' "$RUN"
grep -Fq 'RKLLM_TOKENIZER_PATH="$TOKENIZER"' "$RUN"
if grep -Eq '(systemctl|sudo|/srv/aibrain/production/apps|dawn-stage3)' "$RUN"; then
    echo 'FAIL: runtime capture must not touch services or production application source' >&2
    exit 1
fi
echo 'PASS: tokenizer runtime capture static checks completed.'
