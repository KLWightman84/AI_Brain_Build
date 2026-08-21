#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$ROOT/run.sh"

bash -n "$RUN"
grep -Fq "readonly SOURCE_SHA='6bb2338b4cf1118611053ac6a4c2c9d92ee2327ca02c0c3849d118dbb37278de'" "$RUN"
grep -Fq "calibrated_envelope_reserve_tokens" "$RUN"
grep -Fq 'TOKEN_ENVELOPE_RESERVE = 46' "$RUN" || true
grep -Fq 'mandatory prompt content exceeds safe input budget' "$RUN"
grep -Fq 'selection_policy' "$RUN"
grep -Fq 'AIBRAIN_RKLLM_TOKENIZER' "$RUN"
grep -Fq 'PYTHONPATH=$TOKENIZER_SITE' "$RUN"
grep -Fq 'run_runtime_endpoint_tests' "$RUN"
if grep -Eq '(sudo|apt |git (add|commit|push)|dawn_trace|finish_reason)' "$RUN"; then
    echo 'FAIL: enforcement must not alter packages/source control or retain calibration tracing' >&2
    exit 1
fi

for payload in SERVICE FACTORY TESTS; do
    embedded=$(mktemp)
    trap 'rm -f -- "$embedded"' EXIT
    awk -v marker="${payload}_PAYLOAD" '
        $0 ~ "<<'"'"'" marker "'"'"'" { capture = 1; next }
        capture && $0 == marker { exit }
        capture { print }
    ' "$RUN" | base64 -d >"$embedded"
    case "$payload" in
        SERVICE) expected="$ROOT/staging/src/aibrain_rkllm/service.py" ;;
        FACTORY) expected="$ROOT/staging/src/aibrain_rkllm/wsgi_factory.py" ;;
        TESTS) expected="$ROOT/staging/tests/test_service.py" ;;
    esac
    cmp -s "$embedded" "$expected"
    rm -f -- "$embedded"
done

echo 'PASS: token-aware enforcement static checks completed.'
