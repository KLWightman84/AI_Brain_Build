#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$(mktemp -d)"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

mkdir -p "$FIXTURE/app/src/aibrain_rkllm" "$FIXTURE/app/tests" "$FIXTURE/captures"
git -C "$FIXTURE/app" init -q
git -C "$FIXTURE/app" config user.email capture-test@example.invalid
git -C "$FIXTURE/app" config user.name capture-test
printf 'VALUE = 1\n' >"$FIXTURE/app/src/aibrain_rkllm/service.py"
printf 'def test_ok():\n    assert True\n' >"$FIXTURE/app/tests/test_service.py"
git -C "$FIXTURE/app" add src/aibrain_rkllm/service.py tests/test_service.py
git -C "$FIXTURE/app" commit -qm baseline
printf 'VALUE = 2\n' >"$FIXTURE/app/src/aibrain_rkllm/service.py"
printf 'def test_ok():\n    assert 2 == 2\n' >"$FIXTURE/app/tests/test_service.py"
mkdir -p "$FIXTURE/app/src/aibrain_rkllm.egg-info"
printf 'generated\n' >"$FIXTURE/app/src/aibrain_rkllm.egg-info/PKG-INFO"

AIBRAIN_RKLLM_APP_ROOT="$FIXTURE/app" \
AIBRAIN_CAPTURE_ROOT="$FIXTURE/captures" \
AIBRAIN_RKLLM_PYTHON="$(command -v python3)" \
  bash "$SCRIPT_DIR/run.sh" >/dev/null

ARCHIVE="$(find "$FIXTURE/captures" -maxdepth 1 -name 'rkllm-source-closure-*.tar.gz' -print -quit)"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]]
tar -tzf "$ARCHIVE" | grep -Ex '^(\./)?manifest\.json$' >/dev/null
tar -xOzf "$ARCHIVE" manifest.json >/dev/null
tar -xOzf "$ARCHIVE" unit-tests.txt | grep -Fx 'PASS test_ok' >/dev/null
echo "PASS source-closure capture test"
