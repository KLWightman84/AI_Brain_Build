#!/usr/bin/env bash
# Download and fingerprint one pinned tokenizer candidate in the test tree.
# This does not install dependencies or modify the running RKLLM service.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

REPOSITORY="Qwen/Qwen3.5-4B"
REVISION="${AIBRAIN_TOKENIZER_REVISION:-c7429d5a8ed57f4a9cfdaf1af76a8943eba0ae97}"
TOKENIZER_ROOT="${AIBRAIN_TOKENIZER_ROOT:-/srv/aibrain/test/tokenizers}"
CAPTURE_ROOT="${AIBRAIN_CAPTURE_ROOT:-/srv/aibrain/test/captures}"
ACTIVE_MODEL="${AIBRAIN_ACTIVE_MODEL:-/srv/aibrain/production/models/Qwen3.5-4B_w8a8_rk3588_ctx4096.rkllm}"
URL="${AIBRAIN_TOKENIZER_URL:-https://huggingface.co/$REPOSITORY/resolve/$REVISION/tokenizer.json}"
SAFE_REVISION="${REVISION//[^0-9A-Za-z._-]/_}"
TARGET="$TOKENIZER_ROOT/Qwen3.5-4B-$SAFE_REVISION-tokenizer.json"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: revision must be a full 40-character SHA" >&2; exit 2; }
[[ -f "$ACTIVE_MODEL" ]] || { echo "ERROR: Active RKLLM model is missing: $ACTIVE_MODEL" >&2; exit 1; }
mkdir -p "$TOKENIZER_ROOT" "$CAPTURE_ROOT"

TMPDIR="$(mktemp -d "$CAPTURE_ROOT/.tokenizer-candidate-capture.XXXXXX")"
TEMP="$TMPDIR/tokenizer.json"
ARCHIVE="$CAPTURE_ROOT/tokenizer-candidate-capture-$STAMP.tar.gz"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
umask 077

if [[ -e "$TARGET" ]]; then
    cp -- "$TARGET" "$TEMP"
else
    curl --fail --location --silent --show-error "$URL" -o "$TEMP"
fi

python3 - "$TEMP" "$TARGET" "$ACTIVE_MODEL" "$REPOSITORY" "$REVISION" "$URL" "$STAMP" "$TMPDIR" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
active_model = Path(sys.argv[3])
repository = sys.argv[4]
revision = sys.argv[5]
url = sys.argv[6]
stamp = sys.argv[7]
tmpdir = Path(sys.argv[8])


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


try:
    tokenizer = json.loads(source.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"ERROR: downloaded tokenizer is not valid JSON: {error}")
if not isinstance(tokenizer, dict) or not isinstance(tokenizer.get("model"), dict):
    raise SystemExit("ERROR: tokenizer JSON has no model object")
model_type = tokenizer["model"].get("type")
if not isinstance(model_type, str) or not model_type:
    raise SystemExit("ERROR: tokenizer JSON model type is missing")

tokenizer_sha256 = sha256(source)
if target.exists() and sha256(target) != tokenizer_sha256:
    raise SystemExit(f"ERROR: existing tokenizer candidate differs: {target}")

metadata = {
    "schema": 1,
    "kind": "rkllm_tokenizer_candidate",
    "captured_at_utc": stamp,
    "repository": repository,
    "revision": revision,
    "download_url": url,
    "tokenizer_path": str(target),
    "tokenizer_sha256": tokenizer_sha256,
    "tokenizer_bytes": source.stat().st_size,
    "tokenizer_model_type": model_type,
    "added_token_count": len(tokenizer.get("added_tokens", [])),
    "active_rkllm_model": str(active_model),
    "active_rkllm_model_sha256": sha256(active_model),
    "certification": "candidate only; must be matched to native RKLLM prefill telemetry before use",
}
(tmpdir / "manifest.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
(tmpdir / "tokenizer.sha256").write_text(f"{tokenizer_sha256}  {target.name}\n", encoding="utf-8")
PY

if [[ ! -e "$TARGET" ]]; then
    install -m 0640 "$TEMP" "$TARGET"
fi

if grep -RInE '(gh[pous]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|DAWN-[A-Z0-9-]{12,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Authorization:[[:space:]]*Bearer)' "$TMPDIR" >/dev/null; then
    echo "ERROR: Sensitive-value scan failed; capture archive was not created." >&2
    exit 1
fi

tar -C "$TMPDIR" -czf "$ARCHIVE" manifest.json tokenizer.sha256
echo "PASS: tokenizer candidate capture created."
echo "Archive: $ARCHIVE"
echo "Archive SHA-256: $(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo "Tokenizer candidate: $TARGET"
