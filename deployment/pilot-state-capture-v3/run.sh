#!/usr/bin/env bash
# Capture schema v3: read-only strict-allowlist provenance capture of the verified Stage-3 WebUI/TTS/RKLLM pilot.
# It creates a small sanitized archive under /srv/aibrain/test/captures.

set -euo pipefail

APP=/srv/aibrain/production/apps/AI_Brain_Build
RKLLM_SERVICE=aibrain-rkllm.service
WEBUI_SERVICE=dawn-stage3-webui-tts.service
PYTHON=/srv/aibrain/production/runtime/rkllm-venv/bin/python3

RKLLM_SOURCE="$APP/src/aibrain_rkllm/service.py"
RKLLM_TESTS="$APP/tests/test_service.py"
DAWN_SOURCE=/srv/aibrain/test/builds/dawn-stage3-source
DAWN_BINARY=/srv/aibrain/test/builds/dawn-stage3-webui-tts/dawn
WEBUI_CONFIG=/srv/aibrain/test/AI_Brain_Build/configs/dawn-stage3-webui-tts-alan.toml
ASR_SOURCE="$DAWN_SOURCE/common/src/asr/asr_whisper.c"
BEAM_BACKUP=/srv/aibrain/test/backups/asr_whisper.c-pre-beam6
TTS_MODELS=/srv/aibrain/test/models/piper
WHISPER_MODEL=/srv/aibrain/test/models/whisper.cpp/ggml-small.en.bin

PATCHDIR=/srv/aibrain/test/patches
LOGDIR=/srv/aibrain/test/logs
CAPTURE_ROOT=/srv/aibrain/test/captures
TTS_BUILD=/srv/aibrain/test/builds/dawn-stage3-webui-tts
WEBUI_BUILD=/srv/aibrain/test/builds/dawn-stage3-webui
PPSRC=/srv/aibrain/test/deps/src/piper-phonemize
PPBUILD=/srv/aibrain/test/deps/build/piper-phonemize

EXPECTED_RKLLM_SOURCE_SHA=6bb2338b4cf1118611053ac6a4c2c9d92ee2327ca02c0c3849d118dbb37278de
EXPECTED_RKLLM_TESTS_SHA=db47fb02f432a9c68cba685c19ca717b1bf4e006603fb93f905f52c7f1b7d8ae
EXPECTED_ALAN_MODEL_SHA=0a309668932205e762801f1efc2736cd4b0120329622adf62be09e56339d3330
EXPECTED_ALAN_CONFIG_SHA=c0f0d124e5895c00e7c03b35dcc8287f319a6998a365b182deb5c8e752ee8c1e
EXPECTED_FEATURE_GATE_PATCH_SHA=3021d9bd2974b8c34096b29f5b84c4e577e1a73b2e39ceb45c5a77d596991b0a
SENSITIVE_KEY_PATTERN='(api[_-]?key|password|secret|authorization|cookie|credential|access[_-]?token|refresh[_-]?token|github[_-]?token)[^=]*='
SENSITIVE_TOKEN_PATTERN='gh[pousr]_[[:alnum:]_]{20,}|DAWN-[A-Z0-9-]{10,}'

STAMP=$(date +%Y%m%d-%H%M%S)
STAGE=
ARCHIVE=
TMP_LIST=
FIXTURE_DIR=

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ -z "$TMP_LIST" ] || rm -f "$TMP_LIST"
    [ -z "$FIXTURE_DIR" ] || rm -rf "$FIXTURE_DIR"
    exit "$status"
}
trap cleanup EXIT

require_file() { [ -f "$1" ] || die "Required file is missing: $1"; }
require_dir() { [ -d "$1" ] || die "Required directory is missing: $1"; }
require_executable() { [ -x "$1" ] || die "Required executable is missing: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"; }

check_sha() {
    local expected=$1 path=$2 actual
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ] || die "Unexpected SHA-256 for $path; capture stopped."
}

copy_required() {
    local source=$1 relative=$2
    require_file "$source"
    install -D -m 0644 "$source" "$STAGE/$relative"
}

sanitize_stream() {
    sed -E \
        -e '/(api[_-]?key|password|secret|authorization|cookie|credential|access[_-]?token|refresh[_-]?token|github[_-]?token)[^=]*=/Id' \
        -e '/gh[pousr]_[[:alnum:]_]{20,}/d' \
        -e '/DAWN-[A-Z0-9-]{10,}/d'
}

sensitive_scan() {
    local scan_status
    grep -rniE -i "$SENSITIVE_KEY_PATTERN" "$@"
    scan_status=$?
    if [ "$scan_status" -eq 0 ]; then
        return 0
    fi
    [ "$scan_status" -eq 1 ] || return "$scan_status"

    grep -rnE "$SENSITIVE_TOKEN_PATTERN" "$@"
    scan_status=$?
    if [ "$scan_status" -eq 0 ]; then
        return 0
    fi
    [ "$scan_status" -eq 1 ] || return "$scan_status"
    return 1
}

fixture_must_be_clean() {
    local scan_status
    if sensitive_scan "$1" >/dev/null; then
        die "Sensitive-scan fixture unexpectedly matched: $1"
    else
        scan_status=$?
    fi
    [ "$scan_status" -eq 1 ] || die "Sensitive-scan fixture could not be scanned: $1"
}

fixture_must_match() {
    local scan_status
    if sensitive_scan "$1" >/dev/null; then
        return
    else
        scan_status=$?
    fi
    [ "$scan_status" -eq 1 ] || die "Sensitive-scan fixture could not be scanned: $1"
    die "Sensitive-scan fixture was not detected: $1"
}

assert_loopback_listener() {
    local address=$1 port=$2
    if ! ss -ltnH | awk -v wanted="$address" '$4 == wanted { found = 1 } END { exit !found }'; then
        die "Expected loopback listener is absent: $address"
    fi
    if ss -ltnH | awk -v suffix=":$port" -v wanted="$address" '$4 ~ (suffix "$") && $4 != wanted { bad = 1 } END { exit !bad }'; then
        die "A non-loopback listener is present on port $port."
    fi
}

model_record() {
    local name=$1 path=$2 provenance=$3
    require_file "$path"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$(readlink -f "$path")" "$(stat -c '%s' "$path")" \
        "$(sha256sum "$path" | awk '{print $1}')" "$provenance" \
        >>"$STAGE/models/active-models.tsv"
}

require_executable "$PYTHON"
require_executable "$DAWN_BINARY"
require_command patch
require_dir "$APP/.git"
require_dir "$DAWN_SOURCE"
require_dir "$TTS_BUILD"
require_dir "$WEBUI_BUILD"
require_dir "$PPSRC/.git"
require_dir "$PPBUILD"
for required in \
    "$RKLLM_SOURCE" "$RKLLM_TESTS" "$WEBUI_CONFIG" "$ASR_SOURCE" "$BEAM_BACKUP" \
    "$WHISPER_MODEL" "$TTS_MODELS/en_GB-alan-medium.onnx" \
    "$TTS_MODELS/en_GB-alan-medium.onnx.json"
do
    require_file "$required"
done

check_sha "$EXPECTED_RKLLM_SOURCE_SHA" "$RKLLM_SOURCE"
check_sha "$EXPECTED_RKLLM_TESTS_SHA" "$RKLLM_TESTS"
check_sha "$EXPECTED_ALAN_MODEL_SHA" "$TTS_MODELS/en_GB-alan-medium.onnx"
check_sha "$EXPECTED_ALAN_CONFIG_SHA" "$TTS_MODELS/en_GB-alan-medium.onnx.json"

FEATURE_GATE_PATCH=
for candidate in \
    "$PATCHDIR/dawn-stage3-webui-feature-gating.patch" \
    "/home/ai_brain/Downloads/dawn-stage3-webui-feature-gating.patch"
do
    if [ -f "$candidate" ]; then
        candidate_sha=$(sha256sum "$candidate" | awk '{print $1}')
        if [ "$candidate_sha" = "$EXPECTED_FEATURE_GATE_PATCH_SHA" ] && [ -z "$FEATURE_GATE_PATCH" ]; then
            FEATURE_GATE_PATCH=$candidate
        fi
    fi
done
[ -n "$FEATURE_GATE_PATCH" ] || die "Verified feature-gating patch was not found in /srv/aibrain/test/patches or /home/ai_brain/Downloads."

systemctl --user is-active --quiet "$RKLLM_SERVICE" || die "RKLLM service is not active."
systemctl --user is-active --quiet "$WEBUI_SERVICE" || die "WebUI/TTS service is not active."
assert_loopback_listener 127.0.0.1:8081 8081
assert_loopback_listener 127.0.0.1:3000 3000

RECOVERY_MANIFEST=$(find "$LOGDIR" -maxdepth 1 -type f -name 'pilot-recovery-freeze-*.json' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
[ -n "$RECOVERY_MANIFEST" ] || die "No passed pilot-recovery-freeze manifest was found."
"$PYTHON" - "$RECOVERY_MANIFEST" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest.get("artifact") == "pilot-recovery-freeze", manifest
assert manifest.get("result") == "pass", manifest
assert manifest.get("rkllm", {}).get("context_length") == 4096, manifest
assert manifest.get("rkllm", {}).get("max_new_tokens_verified") == 768, manifest
PY

mkdir -p "$CAPTURE_ROOT"
FIXTURE_DIR=$(mktemp -d "$CAPTURE_ROOT/.pilot-capture-fixtures.XXXXXX")
printf '%s\n' 'www_path = "/srv/aibrain/test/builds/dawn-stage3-source/www"' >"$FIXTURE_DIR/safe-path.toml"
printf '%s\n' 'Api_Key = "fixture-only"' >"$FIXTURE_DIR/mixed-case-key.toml"
printf '%s\n' 'DAWN-ABCDEFGHIJK' >"$FIXTURE_DIR/setup-token.txt"
printf '%s\n' 'dawn-stage3-webui-tts' >"$FIXTURE_DIR/lowercase-dawn.txt"
fixture_must_be_clean "$FIXTURE_DIR/safe-path.toml"
fixture_must_match "$FIXTURE_DIR/mixed-case-key.toml"
fixture_must_match "$FIXTURE_DIR/setup-token.txt"
fixture_must_be_clean "$FIXTURE_DIR/lowercase-dawn.txt"
rm -rf "$FIXTURE_DIR"
FIXTURE_DIR=

STAGE=$(mktemp -d "$CAPTURE_ROOT/.pilot-state-capture.XXXXXX")
ARCHIVE="$CAPTURE_ROOT/pilot-state-capture-$STAMP.tar.gz"
TMP_LIST=$(mktemp /tmp/pilot-state-capture-files.XXXXXX)
mkdir -p "$STAGE"/{adapter,dawn,patches,config,systemd,build,dependencies,models,recovery}

printf '%s\n' \
    '# Stage-3 WebUI/TTS/RKLLM pilot capture (schema v3)' \
    '' \
    'This is a read-only provenance capture of the currently verified pilot.' \
    'It is not a production release and must not be merged into GitHub main without separate approval.' \
    '' \
    'Included: allowlisted active source, accepted patch evidence, sanitized configuration and unit text,' \
    'build/dependency/model manifests, and passed recovery-verification evidence.' \
    '' \
    'Excluded: models, virtual environments, databases, user/runtime state, recordings, operational logs, caches,' \
    'credentials, tokens, secrets, Git metadata, and rejected perf.generate_tokens finish-reason experiments.' \
    '' \
    'The output-limit/continuation problem remains open and is not an accepted change.' \
    >"$STAGE/README.md"

copy_required "$RKLLM_SOURCE" adapter/src/aibrain_rkllm/service.py
for adapter_file in inference.py model.py native.py protocol.py wsgi.py gunicorn_worker.py
do
    copy_required "$APP/src/aibrain_rkllm/$adapter_file" "adapter/src/aibrain_rkllm/$adapter_file"
done
copy_required "$RKLLM_TESTS" adapter/tests/test_service.py
copy_required "$APP/pyproject.toml" adapter/pyproject.toml

git -C "$APP" diff --check
{
    printf 'head=%s\n' "$(git -C "$APP" rev-parse HEAD)"
    printf 'status:\n'
    git -C "$APP" status --short --branch
} >"$STAGE/adapter/git-provenance.txt"
git -C "$APP" diff -- src/aibrain_rkllm/service.py tests/test_service.py >"$STAGE/adapter/accepted-local-diff.patch"
test -s "$STAGE/adapter/accepted-local-diff.patch" || die "Accepted RKLLM local diff is unexpectedly empty."

copy_required "$DAWN_SOURCE/CMakeLists.txt" dawn/CMakeLists.txt
copy_required "$DAWN_SOURCE/src/webui/webui_phone.c" dawn/src/webui/webui_phone.c
copy_required "$DAWN_SOURCE/src/messaging/messaging_sms.c" dawn/src/messaging/messaging_sms.c
copy_required "$DAWN_SOURCE/src/webui/webui_volume_parse.c" dawn/src/webui/webui_volume_parse.c
copy_required "$DAWN_SOURCE/src/core/stage3_text_cleanup_stub.c" dawn/src/core/stage3_text_cleanup_stub.c
copy_required "$DAWN_SOURCE/src/tts/text_to_speech.cpp" dawn/src/tts/text_to_speech.cpp
copy_required "$ASR_SOURCE" dawn/common/src/asr/asr_whisper.c

copy_required "$FEATURE_GATE_PATCH" patches/dawn-stage3-webui-feature-gating.patch
{
    printf 'source=%s\n' "$FEATURE_GATE_PATCH"
    printf 'sha256=%s\n' "$EXPECTED_FEATURE_GATE_PATCH_SHA"
} >"$STAGE/patches/dawn-stage3-webui-feature-gating-provenance.txt"
patch --dry-run --reverse --batch -d "$DAWN_SOURCE" -p1 <"$FEATURE_GATE_PATCH" \
    >"$STAGE/patches/dawn-stage3-webui-feature-gating-reverse-apply.txt" 2>&1 \
    || die "Feature-gating reverse dry-run failed; active source does not match the verified patch."
sha256sum \
    "$DAWN_SOURCE/CMakeLists.txt" \
    "$DAWN_SOURCE/src/webui/webui_phone.c" \
    "$DAWN_SOURCE/src/messaging/messaging_sms.c" \
    "$DAWN_SOURCE/src/webui/webui_volume_parse.c" \
    >"$STAGE/patches/dawn-stage3-webui-feature-gating-current-source-sha256.txt"

for patch_file in dawn-stage3-tts-text-cleanup-gate.patch dawn-stage3-tts-private-espeak-path.patch
do
    copy_required "$PATCHDIR/$patch_file" "patches/$patch_file"
done

if diff -u --label a/common/src/asr/asr_whisper.c --label b/common/src/asr/asr_whisper.c "$BEAM_BACKUP" "$ASR_SOURCE" >"$STAGE/patches/dawn-stage3-asr-beam6.patch"
then
    die "The ASR beam-6 backup and active source are identical."
else
    diff_status=$?
    [ "$diff_status" -eq 1 ] || die "Unable to derive the ASR beam-6 patch."
fi

sanitize_stream <"$WEBUI_CONFIG" >"$STAGE/config/dawn-stage3-webui-tts-alan.toml"
systemctl --user cat "$RKLLM_SERVICE" | sanitize_stream >"$STAGE/systemd/$RKLLM_SERVICE.txt"
systemctl --user cat "$WEBUI_SERVICE" | sanitize_stream >"$STAGE/systemd/$WEBUI_SERVICE.txt"
systemctl --user show "$RKLLM_SERVICE" -p ExecStart -p WorkingDirectory >"$STAGE/systemd/$RKLLM_SERVICE.runtime.txt"
systemctl --user show "$WEBUI_SERVICE" -p ExecStart -p WorkingDirectory >"$STAGE/systemd/$WEBUI_SERVICE.runtime.txt"

if sensitive_scan "$STAGE/config" "$STAGE/systemd"; then
    die "Sensitive-value scan failed; capture archive was not created."
fi

{
    cmake --version | head -1
    cc --version | head -1
    c++ --version | head -1
} >"$STAGE/build/toolchain.txt"
for cache in "$WEBUI_BUILD/CMakeCache.txt" "$TTS_BUILD/CMakeCache.txt"
do
    require_file "$cache"
    cache_name=$(basename "$(dirname "$cache")")
    grep -E '^(DAWN_|ENABLE_|SERVER_ONLY|ONNXRUNTIME_|PIPER_|ESPEAK_|CMAKE_BUILD_TYPE|CMAKE_(C|CXX)_COMPILER)' "$cache" >"$STAGE/build/$cache_name-options.txt" || true
done
{
    sha256sum "$DAWN_BINARY"
    ldd "$DAWN_BINARY"
} >"$STAGE/build/dawn-webui-tts-runtime.txt"

{
    printf 'piper_phonemize_head=%s\n' "$(git -C "$PPSRC" rev-parse HEAD)"
    printf 'piper_phonemize_status:\n'
    git -C "$PPSRC" status --short --branch
    printf '\nPiper build cache (selected):\n'
    grep -E '^(CMAKE_BUILD_TYPE|CMAKE_(C|CXX)_COMPILER|ESPEAK|ONNXRUNTIME)' "$PPBUILD/CMakeCache.txt" || true
} >"$STAGE/dependencies/piper-phonemize.txt"
{
    for package in libespeak-ng-dev libspdlog-dev libsndfile1-dev libopus-dev libsamplerate0-dev libwebsockets-dev cmake
    do
        dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' "$package" 2>/dev/null || true
    done
    for package in spdlog espeak-ng opus samplerate libwebsockets
    do
        printf '%s ' "$package"
        pkg-config --modversion "$package" 2>/dev/null || printf 'NOT FOUND\n'
    done
} >"$STAGE/dependencies/packages.txt"

RKLLM_ENV=$(systemctl --user show "$RKLLM_SERVICE" -p Environment --value)
RKLLM_MODEL=$(printf '%s\n' "$RKLLM_ENV" | tr ' ' '\n' | sed -n 's/^AIBRAIN_RKLLM_MODEL=//p')
RKLLM_LIBRARY=$(printf '%s\n' "$RKLLM_ENV" | tr ' ' '\n' | sed -n 's/^AIBRAIN_RKLLM_LIBRARY=//p')
[ -n "$RKLLM_MODEL" ] || die "Unable to resolve the active RKLLM model path."
[ -n "$RKLLM_LIBRARY" ] || die "Unable to resolve the active RKLLM runtime library path."
require_file "$RKLLM_MODEL"
require_file "$RKLLM_LIBRARY"
printf 'name\tpath\tbytes\tsha256\tprovenance\n' >"$STAGE/models/active-models.tsv"
model_record rkllm "$RKLLM_MODEL" 'production RKLLM artifact; model binary excluded'
model_record whisper-small-en "$WHISPER_MODEL" 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin'
model_record piper-alan-onnx "$TTS_MODELS/en_GB-alan-medium.onnx" 'https://github.com/KLWightman84/AI-clean-slate/tree/main/piper'
model_record piper-alan-config "$TTS_MODELS/en_GB-alan-medium.onnx.json" 'https://github.com/KLWightman84/AI-clean-slate/tree/main/piper'
{
    printf 'rkllm_runtime_library=%s\n' "$(readlink -f "$RKLLM_LIBRARY")"
    printf 'piper_phonemize_library=%s\n' "$(readlink -f "$PPBUILD/libpiper_phonemize.so")"
    printf 'espeak_data_path=%s\n' "$(readlink -f "$PPBUILD/ei/share/espeak-ng-data")"
} >"$STAGE/dependencies/runtime-paths.txt"

copy_required "$RECOVERY_MANIFEST" recovery/pilot-recovery-freeze.json
{
    printf 'rkllm_service=%s\n' "$(systemctl --user is-active "$RKLLM_SERVICE")"
    printf 'webui_service=%s\n' "$(systemctl --user is-active "$WEBUI_SERVICE")"
    printf 'rkllm_listener=127.0.0.1:8081\n'
    printf 'webui_listener=127.0.0.1:3000\n'
    printf 'capture_timestamp=%s\n' "$(date --iso-8601=seconds)"
} >"$STAGE/recovery/current-state.txt"

find "$STAGE" -type f -printf '%P\n' | sort >"$STAGE/PAYLOAD_FILES"
while IFS= read -r relative
do
    case "$relative" in
        README.md|PAYLOAD_FILES|SHA256SUMS|adapter/*|dawn/*|patches/*|config/*|systemd/*|build/*|dependencies/*|models/*|recovery/*) ;;
        *) die "Allowlist violation in capture staging: $relative" ;;
    esac
done <"$STAGE/PAYLOAD_FILES"

while IFS= read -r relative
do
    sha256sum "$STAGE/$relative"
done <"$STAGE/PAYLOAD_FILES" >"$STAGE/SHA256SUMS"

tar -C "$STAGE" -czf "$ARCHIVE" .
tar -tzf "$ARCHIVE" >/dev/null || die "Archive integrity test failed."
tar -tzf "$ARCHIVE" | sed -e 's#^\./##' -e '/^$/d' | grep -v '/$' | sort >"$TMP_LIST"
while IFS= read -r relative
do
    case "$relative" in
        README.md|PAYLOAD_FILES|SHA256SUMS|adapter/*|dawn/*|patches/*|config/*|systemd/*|build/*|dependencies/*|models/*|recovery/*) ;;
        *) die "Archive allowlist violation: $relative" ;;
    esac
done <"$TMP_LIST"

echo "PASS: sanitized pilot capture created."
echo "Archive: $ARCHIVE"
echo "Archive SHA-256: $(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo "Archive size: $(du -h "$ARCHIVE" | awk '{print $1}')"
echo "Archive files: $(wc -l <"$TMP_LIST")"
