#!/usr/bin/env bash
# Recovery-and-freeze verification for the Stage-3 WebUI/TTS/RKLLM pilot.
# This script makes no source or configuration edits. It performs controlled
# user-service restarts so the checked source is proven to load at runtime.

set -euo pipefail

APP=/srv/aibrain/production/apps/AI_Brain_Build
RKLLM_SOURCE="$APP/src/aibrain_rkllm/service.py"
RKLLM_TESTS="$APP/tests/test_service.py"
PYTHON=/srv/aibrain/production/runtime/rkllm-venv/bin/python3
RKLLM_SERVICE=aibrain-rkllm.service

DAWN_SOURCE=/srv/aibrain/test/builds/dawn-stage3-source
DAWN_BINARY=/srv/aibrain/test/builds/dawn-stage3-webui-tts/dawn
WEBUI_SERVICE=dawn-stage3-webui-tts.service
WEBUI_CONFIG=/srv/aibrain/test/AI_Brain_Build/configs/dawn-stage3-webui-tts-alan.toml
ASR_SOURCE="$DAWN_SOURCE/common/src/asr/asr_whisper.c"
TTS_MODELS=/srv/aibrain/test/models/piper
ESPEAK_DATA=/srv/aibrain/test/deps/build/piper-phonemize/ei/share/espeak-ng-data
LOGDIR=/srv/aibrain/test/logs

# These are the accepted pilot adapter files after the failed diagnostic's
# rollback. A mismatch is a stop condition, not something to overwrite.
EXPECTED_RKLLM_SOURCE_SHA=6bb2338b4cf1118611053ac6a4c2c9d92ee2327ca02c0c3849d118dbb37278de
EXPECTED_RKLLM_TESTS_SHA=db47fb02f432a9c68cba685c19ca717b1bf4e006603fb93f905f52c7f1b7d8ae
EXPECTED_ALAN_MODEL_SHA=0a309668932205e762801f1efc2736cd4b0120329622adf62be09e56339d3330
EXPECTED_ALAN_CONFIG_SHA=c0f0d124e5895c00e7c03b35dcc8287f319a6998a365b182deb5c8e752ee8c1e

TMPDIR=
STAMP=$(date +%Y%m%d-%H%M%S)
MANIFEST=

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT
    [ -z "$TMPDIR" ] || rm -rf "$TMPDIR"
    exit "$status"
}
trap cleanup EXIT

require_file() {
    [ -f "$1" ] || die "Required file is missing: $1"
}

require_executable() {
    [ -x "$1" ] || die "Required executable is missing: $1"
}

check_sha() {
    local expected=$1
    local path=$2
    local actual
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ] || die "Unexpected SHA-256 for $path; no files changed."
}

wait_for_http() {
    local url=$1
    local seconds=$2
    local attempt
    for attempt in $(seq 1 "$seconds"); do
        if curl --fail --silent --show-error "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_listener() {
    local address=$1
    local seconds=$2
    local attempt
    for attempt in $(seq 1 "$seconds"); do
        if ss -ltnH | awk -v wanted="$address" '$4 == wanted { found = 1 } END { exit !found }'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

require_file "$RKLLM_SOURCE"
require_file "$RKLLM_TESTS"
require_file "$WEBUI_CONFIG"
require_file "$ASR_SOURCE"
require_file "$TTS_MODELS/en_GB-alan-medium.onnx"
require_file "$TTS_MODELS/en_GB-alan-medium.onnx.json"
require_file "$ESPEAK_DATA/phontab"
require_executable "$PYTHON"
require_executable "$DAWN_BINARY"

check_sha "$EXPECTED_RKLLM_SOURCE_SHA" "$RKLLM_SOURCE"
check_sha "$EXPECTED_RKLLM_TESTS_SHA" "$RKLLM_TESTS"
check_sha "$EXPECTED_ALAN_MODEL_SHA" "$TTS_MODELS/en_GB-alan-medium.onnx"
check_sha "$EXPECTED_ALAN_CONFIG_SHA" "$TTS_MODELS/en_GB-alan-medium.onnx.json"

# Reject residue from the two deliberately rejected finish-reason experiments.
if grep -nE 'last-run-diagnostics|perf_generate_tokens|RKLLM_RUN_WAITING|generated_token_count' "$RKLLM_SOURCE"; then
    die "Rejected finish-reason diagnostic residue found in the adapter source."
fi

"$PYTHON" -m py_compile "$RKLLM_SOURCE" "$RKLLM_TESTS"
"$PYTHON" - "$RKLLM_TESTS" <<'PY'
import runpy
import sys

tests = runpy.run_path(sys.argv[1])
for name in sorted(key for key in tests if key.startswith("test_")):
    tests[name]()
    print(f"PASS {name}")
PY

echo "=== RKLLM RESTART AND HEALTH ==="
systemctl --user restart "$RKLLM_SERVICE"
wait_for_http http://127.0.0.1:8081/healthz 60 || die "RKLLM did not become healthy after restart."

TMPDIR=$(mktemp -d /tmp/pilot-recovery-freeze.XXXXXX)
curl --fail --silent --show-error http://127.0.0.1:8081/healthz >"$TMPDIR/health.json"
curl --fail --silent --show-error http://127.0.0.1:8081/v1/dawn/status >"$TMPDIR/status.json"

"$PYTHON" - "$TMPDIR/health.json" "$TMPDIR/status.json" <<'PY'
import json
import sys

health = json.load(open(sys.argv[1], encoding="utf-8"))
status = json.load(open(sys.argv[2], encoding="utf-8"))
assert health == {"model": "rkllm", "service": "aibrain-rkllm", "status": "ok"}, health
assert status == {"backend": "rkllm", "max_context_length": 4096, "model": "rkllm"}, status
PY

if ! ss -ltnH | awk '$4 == "127.0.0.1:8081" { found = 1 } END { exit !found }'; then
    die "RKLLM is not listening only at the expected loopback address."
fi
if ! ss -ltnH | awk '$4 ~ /:8081$/ && $4 != "127.0.0.1:8081" { bad = 1 } END { exit bad }'; then
    die "RKLLM has a non-loopback listener on port 8081."
fi

echo "=== CONTEXT AND STREAMING CHECKS ==="
context_response=$(curl --fail --silent --show-error --max-time 90 \
    -H 'Content-Type: application/json' \
    -d '{"model":"rkllm","max_tokens":16,"messages":[{"role":"system","content":"For this diagnostic, reply with exactly CONTEXT-OK and nothing else."},{"role":"user","content":"Respond now."}]}' \
    http://127.0.0.1:8081/v1/chat/completions)
"$PYTHON" - "$context_response" <<'PY'
import json
import sys

choice = json.loads(sys.argv[1])["choices"][0]
assert choice["message"]["content"] == "CONTEXT-OK", choice
assert choice["finish_reason"] == "stop", choice
PY

curl --fail --silent --show-error --no-buffer --max-time 120 \
    -H 'Content-Type: application/json' \
    -d '{"model":"rkllm","stream":true,"max_tokens":8,"messages":[{"role":"system","content":"Reply with exactly STREAM-OK and nothing else."},{"role":"user","content":"Respond now."}]}' \
    http://127.0.0.1:8081/v1/chat/completions >"$TMPDIR/stream.txt"
grep -F 'STREAM-OK' "$TMPDIR/stream.txt" >/dev/null || die "RKLLM streaming content check failed."
grep -F 'data: [DONE]' "$TMPDIR/stream.txt" >/dev/null || die "RKLLM streaming completion check failed."

echo "=== 768-TOKEN CAPACITY CHECK ==="
curl --fail --silent --show-error --max-time 300 \
    -H 'Content-Type: application/json' \
    -d '{"model":"rkllm","max_tokens":768,"messages":[{"role":"user","content":"Write an original story about a blacksmith in approximately 500 words. End with the exact marker [END]."}]}' \
    http://127.0.0.1:8081/v1/chat/completions >"$TMPDIR/long-response.json"
"$PYTHON" - "$TMPDIR/long-response.json" <<'PY'
import json
import sys

choice = json.load(open(sys.argv[1], encoding="utf-8"))["choices"][0]
assert "[END]" in choice["message"]["content"], choice
assert choice["finish_reason"] == "stop", choice
PY
systemctl --user is-active --quiet "$RKLLM_SERVICE" || die "RKLLM service failed after the capacity check."

echo "=== WEBUI/TTS RESTART AND LOCAL-BIND CHECK ==="
grep -q '^model = "small.en"$' "$WEBUI_CONFIG" || die "WebUI config is not pinned to Whisper small.en."
grep -F 'wctx->wparams.beam_search.beam_size = 6;' "$ASR_SOURCE" >/dev/null || die "Beam-search size 6 is not present in the ASR source."

systemctl --user restart "$WEBUI_SERVICE"
wait_for_listener 127.0.0.1:3000 90 || die "WebUI did not listen on 127.0.0.1:3000 after restart."
systemctl --user is-active --quiet "$WEBUI_SERVICE" || die "WebUI service is not active."
if ! ss -ltnH | awk '$4 ~ /:3000$/ && $4 != "127.0.0.1:3000" { bad = 1 } END { exit bad }'; then
    die "WebUI has a non-loopback listener on port 3000."
fi

WEBUI_LOG=$(journalctl --user -u "$WEBUI_SERVICE" --no-pager -n 500)
printf '%s\n' "$WEBUI_LOG" | grep -F 'Loaded TTS voice model: en_GB-alan-medium' >/dev/null || die "Alan voice load was not observed in the current WebUI service journal."
printf '%s\n' "$WEBUI_LOG" | grep -F 'Initialized piper' >/dev/null || die "Piper initialization was not observed in the current WebUI service journal."
printf '%s\n' "$WEBUI_LOG" | grep -F 'WebUI server started on port 3000' >/dev/null || die "WebUI start was not observed in the current service journal."

mkdir -p "$LOGDIR"
MANIFEST="$LOGDIR/pilot-recovery-freeze-$STAMP.json"
"$PYTHON" - "$MANIFEST" "$RKLLM_SOURCE" "$RKLLM_TESTS" "$DAWN_BINARY" "$WEBUI_CONFIG" "$ASR_SOURCE" "$TTS_MODELS/en_GB-alan-medium.onnx" "$TTS_MODELS/en_GB-alan-medium.onnx.json" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

output = Path(sys.argv[1])
paths = [Path(path) for path in sys.argv[2:]]

def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()

output.write_text(json.dumps({
    "artifact": "pilot-recovery-freeze",
    "result": "pass",
    "files": {str(path): digest(path) for path in paths},
    "rkllm": {"endpoint": "127.0.0.1:8081", "context_length": 4096, "max_new_tokens_verified": 768},
    "webui": {"endpoint": "127.0.0.1:3000", "asr_model": "small.en", "beam_size": 6, "tts_voice": "en_GB-alan-medium"},
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "PASS: recovery and pilot-freeze verification completed."
echo "Sanitized manifest: $MANIFEST"
