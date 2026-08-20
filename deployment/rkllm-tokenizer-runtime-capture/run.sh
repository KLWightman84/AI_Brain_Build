#!/usr/bin/env bash
# Capture a hash-pinned, test-only Python tokenizer runtime for RKLLM calibration.
# This script never edits production source, configuration, services, or system packages.
set -euo pipefail

readonly TOKENIZER='/srv/aibrain/test/tokenizers/Qwen3.5-4B-c7429d5a8ed57f4a9cfdaf1af76a8943eba0ae97-tokenizer.json'
readonly TOKENIZER_SHA='5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42'
readonly ACTIVE_MODEL='/srv/aibrain/production/models/Qwen3.5-4B_w8a8_rk3588_ctx4096.rkllm'
readonly ACTIVE_MODEL_SHA='f733cb8acc42fc8ce486c965f673da7918fbc1a1a6ae22c7991e389c34963056'
readonly TOKENIZERS_VERSION='0.21.4'
readonly TEST_ROOT='/srv/aibrain/test/deps/rkllm-tokenizer-runtime'
readonly WHEEL_CACHE="$TEST_ROOT/wheels"
readonly VENV="$TEST_ROOT/venv-tokenizers-$TOKENIZERS_VERSION"
readonly CAPTURE_ROOT='/srv/aibrain/test/captures'

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_file_sha() {
    local path="$1" expected="$2"
    [[ -f "$path" ]] || fail "Required file is missing: $path"
    local observed
    observed=$(sha256sum "$path" | awk '{print $1}')
    [[ "$observed" == "$expected" ]] || fail "SHA-256 mismatch for $path"
}

command -v python3 >/dev/null || fail 'python3 is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'
command -v tar >/dev/null || fail 'tar is required'

require_file_sha "$TOKENIZER" "$TOKENIZER_SHA"
require_file_sha "$ACTIVE_MODEL" "$ACTIVE_MODEL_SHA"

mkdir -p "$WHEEL_CACHE" "$CAPTURE_ROOT"
TMP_DIR=$(mktemp -d "$CAPTURE_ROOT/.rkllm-tokenizer-runtime.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT

# Download only a wheel into the test cache.  The installed runtime below uses
# that exact local wheel; production's interpreter and site packages stay untouched.
python3 -m pip download \
    --only-binary=:all: \
    --no-deps \
    --dest "$TMP_DIR" \
    "tokenizers==$TOKENIZERS_VERSION"

mapfile -t wheels < <(find "$TMP_DIR" -maxdepth 1 -type f -name "tokenizers-${TOKENIZERS_VERSION}-*.whl" -printf '%f\n' | sort)
[[ "${#wheels[@]}" -eq 1 ]] || fail "Expected exactly one tokenizers ${TOKENIZERS_VERSION} wheel"
readonly WHEEL_NAME="${wheels[0]}"
readonly WHEEL_PATH="$WHEEL_CACHE/$WHEEL_NAME"
if [[ -e "$WHEEL_PATH" ]]; then
    require_file_sha "$WHEEL_PATH" "$(sha256sum "$TMP_DIR/$WHEEL_NAME" | awk '{print $1}')"
else
    install -m 0644 "$TMP_DIR/$WHEEL_NAME" "$WHEEL_PATH"
fi

if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --no-index --no-deps "$WHEEL_PATH"

TOKENIZER="$TOKENIZER" "$VENV/bin/python" - <<'PY' >"$TMP_DIR/runtime-check.json"
import json
import os

from tokenizers import Tokenizer, __version__

tokenizer = Tokenizer.from_file(os.environ['TOKENIZER'])
samples = {
    'ascii': 'CURRENT USER REQUEST: Reply exactly READY.',
    'unicode': 'Jarvis — 你好 👋',
    'dense': 'aGVsbG8vKysvPT09' * 8,
}
counts = {name: len(tokenizer.encode(text, add_special_tokens=False).ids) for name, text in samples.items()}
if any(count <= 0 for count in counts.values()):
    raise SystemExit('tokenizer returned an empty encoding')
print(json.dumps({'tokenizers_version': __version__, 'sample_token_counts': counts}, sort_keys=True))
PY

python3 - "$TMP_DIR/manifest.json" "$TMP_DIR/runtime-check.json" "$WHEEL_PATH" "$TOKENIZER" "$ACTIVE_MODEL" <<'PY'
import hashlib
import json
import pathlib
import sys
import time

manifest_path, runtime_check_path, wheel_path, tokenizer_path, model_path = map(pathlib.Path, sys.argv[1:])

def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

runtime_check = json.loads(runtime_check_path.read_text())
manifest = {
    'schema': 1,
    'kind': 'rkllm_tokenizer_runtime_candidate',
    'captured_at_utc': time.strftime('%Y%m%d-%H%M%S', time.gmtime()),
    'certification': 'candidate only; native RKLLM prefill telemetry calibration is still required',
    'active_rkllm_model': str(model_path),
    'active_rkllm_model_sha256': sha256(model_path),
    'tokenizer_path': str(tokenizer_path),
    'tokenizer_sha256': sha256(tokenizer_path),
    'wheel_path': str(wheel_path),
    'wheel_filename': wheel_path.name,
    'wheel_sha256': sha256(wheel_path),
    **runtime_check,
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY

sha256sum "$WHEEL_PATH" >"$TMP_DIR/wheel.sha256"
sha256sum "$TOKENIZER" >"$TMP_DIR/tokenizer.sha256"
ARCHIVE="$CAPTURE_ROOT/rkllm-tokenizer-runtime-capture-$(date -u +%Y%m%d-%H%M%S).tar.gz"
tar -C "$TMP_DIR" -czf "$ARCHIVE" manifest.json wheel.sha256 tokenizer.sha256 runtime-check.json

printf 'PASS: tokenizer runtime candidate captured.\n'
printf 'Archive: %s\n' "$ARCHIVE"
printf 'Archive SHA-256: %s\n' "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf 'Wheel SHA-256: %s\n' "$(sha256sum "$WHEEL_PATH" | awk '{print $1}')"
printf 'Wheel cache: %s\n' "$WHEEL_PATH"
