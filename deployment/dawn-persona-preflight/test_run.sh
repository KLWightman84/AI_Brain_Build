#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$ROOT/run.sh"
bash -n "$RUN"
grep -Fq 'Read-only discovery' "$RUN"
if grep -Eq '(systemctl|sudo|apt |sed -i|rm -rf.*(source|config))' "$RUN"; then
  echo 'FAIL: preflight must not mutate DAWN' >&2; exit 1
fi
echo 'PASS: DAWN persona preflight static checks completed.'
