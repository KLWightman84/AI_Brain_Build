#!/usr/bin/env bash
# Read-only provenance capture for the active RKLLM WSGI factory.
set -euo pipefail

readonly APP='/srv/aibrain/production/apps/AI_Brain_Build'
readonly FACTORY="$APP/src/aibrain_rkllm/wsgi_factory.py"
readonly CAPTURE_ROOT='/srv/aibrain/test/captures'

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for command in git sha256sum tar mktemp python3; do
    command -v "$command" >/dev/null || fail "Required command is missing: $command"
done
[[ -d "$APP/.git" ]] || fail "Expected Git checkout is missing: $APP"
[[ -f "$FACTORY" ]] || fail "Required file is missing: $FACTORY"

before_sha=$(sha256sum "$FACTORY" | awk '{print $1}')
stamp=$(date -u +%Y%m%d-%H%M%S)
tmp_dir=$(mktemp -d "$CAPTURE_ROOT/.rkllm-factory-provenance.XXXXXX")
archive="$CAPTURE_ROOT/rkllm-factory-provenance-$stamp.tar.gz"

cleanup() {
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

git -C "$APP" status --short --branch >"$tmp_dir/git-status.txt"
git -C "$APP" rev-parse HEAD >"$tmp_dir/git-head.txt"
git -C "$APP" diff --check >"$tmp_dir/diff-check.txt"
git -C "$APP" diff -- src/aibrain_rkllm/wsgi_factory.py >"$tmp_dir/factory-worktree.patch"
git -C "$APP" diff --cached -- src/aibrain_rkllm/wsgi_factory.py >"$tmp_dir/factory-index.patch"
git -C "$APP" ls-files -s -- src/aibrain_rkllm/wsgi_factory.py >"$tmp_dir/factory-index-entry.txt"

python3 - "$tmp_dir/manifest.json" "$before_sha" <<'PY'
import json
import sys
import time

path, factory_sha = sys.argv[1:]
manifest = {
    "schema": 1,
    "kind": "rkllm_wsgi_factory_provenance_capture",
    "captured_at_utc": time.strftime("%Y%m%d-%H%M%S", time.gmtime()),
    "factory_path": "src/aibrain_rkllm/wsgi_factory.py",
    "factory_sha256": factory_sha,
    "limitations": [
        "Read-only evidence capture; no source, configuration, service, or runtime state is changed.",
        "The archive contains source-control provenance and any Git patch for the factory only.",
    ],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

after_sha=$(sha256sum "$FACTORY" | awk '{print $1}')
[[ "$before_sha" == "$after_sha" ]] || fail 'Factory hash changed during read-only capture'

if grep -RniE '(gho_|github_pat_|DAWN-[A-Z0-9-]{12,}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' "$tmp_dir"; then
    fail 'Sensitive-value scan failed; capture archive was not created'
fi

tar -C "$tmp_dir" -czf "$archive" \
    manifest.json git-status.txt git-head.txt diff-check.txt \
    factory-worktree.patch factory-index.patch factory-index-entry.txt

printf 'PASS: RKLLM WSGI factory provenance capture created.\n'
printf 'Archive: %s\n' "$archive"
printf 'Archive SHA-256: %s\n' "$(sha256sum "$archive" | awk '{print $1}')"
