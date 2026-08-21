#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$ROOT/run.sh"

bash -n "$RUN"
grep -Fq 'Read-only provenance capture' "$RUN"
grep -Fq 'Factory hash changed during read-only capture' "$RUN"
grep -Fq 'Sensitive-value scan failed; capture archive was not created' "$RUN"
if grep -Eq '(systemctl|sudo|apt |git (add|commit|push)|rm -rf.*production)' "$RUN"; then
    echo 'FAIL: provenance capture must not mutate the running system' >&2
    exit 1
fi

echo 'PASS: factory provenance capture static checks completed.'
