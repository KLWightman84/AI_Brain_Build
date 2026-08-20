#!/usr/bin/env bash
# Read-only capture of the active RKLLM adapter delta.  It does not modify the
# adapter, services, configuration, model, dependencies, or Git working tree.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

APP_ROOT="${AIBRAIN_RKLLM_APP_ROOT:-/srv/aibrain/production/apps/AI_Brain_Build}"
CAPTURE_ROOT="${AIBRAIN_CAPTURE_ROOT:-/srv/aibrain/test/captures}"
PYTHON="${AIBRAIN_RKLLM_PYTHON:-/srv/aibrain/production/runtime/rkllm-venv/bin/python3}"
SERVICE_REL="src/aibrain_rkllm/service.py"
TEST_REL="tests/test_service.py"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

require_file() {
    [[ -f "$1" ]] || { echo "ERROR: Required file is missing: $1" >&2; exit 1; }
}

require_file "$APP_ROOT/$SERVICE_REL"
require_file "$APP_ROOT/$TEST_REL"
require_file "$PYTHON"
git -C "$APP_ROOT" rev-parse --is-inside-work-tree >/dev/null
mkdir -p "$CAPTURE_ROOT"

TMP="$(mktemp -d "$CAPTURE_ROOT/.source-closure-capture.XXXXXX")"
ARCHIVE="$CAPTURE_ROOT/rkllm-source-closure-${STAMP}.tar.gz"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
umask 077

mapfile -t TRACKED_CHANGED < <(git -C "$APP_ROOT" diff --name-only HEAD)
for path in "${TRACKED_CHANGED[@]}"; do
    case "$path" in
        "$SERVICE_REL"|"$TEST_REL") ;;
        *) echo "ERROR: Unreviewed tracked change blocks source closure: $path" >&2; exit 1 ;;
    esac
done

mapfile -t UNTRACKED < <(git -C "$APP_ROOT" ls-files --others --exclude-standard)
for path in "${UNTRACKED[@]}"; do
    case "$path" in
        src/aibrain_rkllm.egg-info/*|src/aibrain_rkllm/__pycache__/*|tests/__pycache__/*) ;;
        *) echo "ERROR: Unreviewed untracked file blocks source closure: $path" >&2; exit 1 ;;
    esac
done

git -C "$APP_ROOT" status --short >"$TMP/git-status.txt"
git -C "$APP_ROOT" rev-parse HEAD >"$TMP/git-head.txt"
git -C "$APP_ROOT" remote -v >"$TMP/git-remotes.txt" || true
git -C "$APP_ROOT" diff --check HEAD >"$TMP/diff-check.txt"
git -C "$APP_ROOT" diff --binary HEAD -- "$SERVICE_REL" "$TEST_REL" >"$TMP/adapter.patch"
printf '%s\n' "${UNTRACKED[@]}" >"$TMP/generated-untracked.txt"
sha256sum "$APP_ROOT/$SERVICE_REL" "$APP_ROOT/$TEST_REL" >"$TMP/current-file-sha256.txt"

"$PYTHON" -m py_compile "$APP_ROOT/$SERVICE_REL" "$APP_ROOT/$TEST_REL" \
    >"$TMP/py-compile.txt" 2>&1
"$PYTHON" - "$APP_ROOT/$TEST_REL" >"$TMP/unit-tests.txt" 2>&1 <<'PY'
import runpy
import sys

tests = runpy.run_path(sys.argv[1])
for name in sorted(key for key in tests if key.startswith("test_")):
    tests[name]()
    print(f"PASS {name}")
PY

if grep -RInE '(gh[pous]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|DAWN-[A-Z0-9-]{12,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Authorization:[[:space:]]*Bearer)' "$TMP" >/dev/null; then
    echo "ERROR: Sensitive-value scan failed; capture archive was not created." >&2
    exit 1
fi

export APP_ROOT TMP SERVICE_REL TEST_REL STAMP
"$PYTHON" - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["APP_ROOT"])
tmp = Path(os.environ["TMP"])
files = [os.environ["SERVICE_REL"], os.environ["TEST_REL"]]
payload = {
    "schema": 1,
    "kind": "rkllm_source_closure",
    "captured_at_utc": os.environ["STAMP"],
    "source_root": str(root),
    "base_commit": (tmp / "git-head.txt").read_text().strip(),
    "changed_files": files,
    "generated_untracked": [line for line in (tmp / "generated-untracked.txt").read_text().splitlines() if line],
    "current_sha256": {
        path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in files
    },
    "limitations": [
        "This is a read-only source capture; it is not a deployment or recovery point.",
        "Only the approved adapter source and its tests may be modified; unknown changes abort capture.",
        "No configuration, model, service environment, or logs are included.",
    ],
}
(tmp / "manifest.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY

tar -C "$TMP" -czf "$ARCHIVE" \
    manifest.json git-status.txt git-head.txt git-remotes.txt diff-check.txt \
    adapter.patch generated-untracked.txt current-file-sha256.txt py-compile.txt unit-tests.txt

echo "PASS: RKLLM source-closure capture created."
echo "Archive: $ARCHIVE"
echo "Archive SHA-256: $(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo "Review manifest: tar -xOzf $ARCHIVE ./manifest.json"
