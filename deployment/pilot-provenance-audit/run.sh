#!/usr/bin/env bash
# Evidence-only provenance capture for the Stage-3 WebUI/TTS/RKLLM pilot.
# It is intentionally read-only outside its new capture directory.

set -uo pipefail
umask 077

readonly CAPTURE_ROOT="/srv/aibrain/test/captures"
readonly DAWN_SOURCE="/srv/aibrain/test/builds/dawn-stage3-source"
readonly DAWN_BUILD="/srv/aibrain/test/builds/dawn-stage3-webui-tts"
readonly DAWN_BINARY="${DAWN_BUILD}/dawn"
readonly DAWN_CONFIG="/srv/aibrain/test/AI_Brain_Build/configs/dawn-stage3-webui-tts-alan.toml"
readonly RKLLM_APP="/srv/aibrain/production/apps/AI_Brain_Build"
readonly RKLLM_SERVICE="aibrain-rkllm.service"
readonly WEBUI_SERVICE="dawn-stage3-webui-tts.service"
readonly RKLLM_LIBRARY="/srv/aibrain/production/runtime/librkllmrt.so"
readonly RKLLM_MODEL="/srv/aibrain/production/models/Qwen3.5-4B_w8a8_rk3588_ctx4096.rkllm"
readonly WHISPER_MODEL="/srv/aibrain/test/models/whisper.cpp/ggml-small.en.bin"
readonly ALAN_MODEL="/srv/aibrain/test/models/piper/en_GB-alan-medium.onnx"
readonly ALAN_JSON="/srv/aibrain/test/models/piper/en_GB-alan-medium.onnx.json"
readonly PIPER_SOURCE="/srv/aibrain/test/deps/src/piper-phonemize"
readonly PIPER_BUILD="/srv/aibrain/test/deps/build/piper-phonemize"
readonly PATCH_ROOT="/srv/aibrain/test/patches"
readonly FEATURE_PATCH="${HOME}/Downloads/dawn-stage3-webui-feature-gating.patch"
readonly PROVENANCE_BASE="9ed366587bc409389665536caba061eb9fc95e36"

stage=""
archive=""
declare -A GATE_STATE
declare -A GATE_NOTE

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${stage}" && -d "${stage}" ]]; then
        case "${stage}" in
            "${CAPTURE_ROOT}"/.pilot-provenance-audit.*) rm -rf -- "${stage}" ;;
        esac
    fi
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

optional_command() {
    command -v "$1" >/dev/null 2>&1
}

sanitize_url() {
    sed -E 's#(https?|ssh)://[^/@[:space:]]+@#\1://<redacted>@#g'
}

gate() {
    local number="$1"
    local state="$2"
    shift 2
    GATE_STATE["${number}"]="${state}"
    GATE_NOTE["${number}"]="$*"
}

service_is_active() {
    systemctl --user is-active --quiet "$1"
}

loopback_listener_present() {
    local port="$1"
    ss -ltnH 2>/dev/null | awk -v target="127.0.0.1:${port}" '$4 == target { found = 1 } END { exit(found ? 0 : 1) }'
}

capture_cmd() {
    local rel="$1"
    shift
    local out="${stage}/${rel}"
    mkdir -p "$(dirname "${out}")"
    {
        printf '# command:'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
        local rc=$?
        printf '\n# exit_status: %d\n' "${rc}"
    } >"${out}" 2>&1 || true
}

record_hash() {
    local path="$1"
    local out="$2"
    mkdir -p "$(dirname "${out}")"
    if [[ -f "${path}" ]]; then
        {
            printf 'path: %s\n' "${path}"
            stat -c 'bytes: %s' "${path}"
            sha256sum "${path}"
        } >"${out}"
    else
        printf 'MISSING: %s\n' "${path}" >"${out}"
    fi
}

record_tree_manifest() {
    local path="$1"
    local out="$2"
    mkdir -p "$(dirname "${out}")"
    if [[ ! -d "${path}" ]]; then
        printf 'MISSING DIRECTORY: %s\n' "${path}" >"${out}"
        return
    fi
    (
        cd "${path}" || exit 1
        find . -type f \
            ! -path './.git/*' \
            ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*' \
            ! -path '*.egg-info/*' ! -name '*.pyc' \
            ! -name '.env' ! -name '.env.*' \
            ! -iname '*secret*' ! -iname '*credential*' \
            ! -iname '*.pem' ! -iname '*.key' \
            -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) >"${out}" 2>&1 || true
}

record_tree_archive_hash() {
    local path="$1"
    local out="$2"
    mkdir -p "$(dirname "${out}")"
    if [[ ! -d "${path}" ]]; then
        printf 'MISSING DIRECTORY: %s\n' "${path}" >"${out}"
        return
    fi
    (
        cd "${path}" || exit 1
        tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
            --exclude='./.git' --exclude='./.env' --exclude='./.env.*' \
            --exclude='*/__pycache__/*' --exclude='*/.pytest_cache/*' \
            --exclude='*.egg-info/*' --exclude='*.pyc' \
            --exclude='*secret*' --exclude='*credential*' \
            --exclude='*.pem' --exclude='*.key' \
            -cf - . | sha256sum
    ) >"${out}" 2>&1 || true
}

record_git_identity() {
    local path="$1"
    local prefix="$2"
    local identity="${stage}/${prefix}/git-identity.txt"
    mkdir -p "$(dirname "${identity}")"
    {
        printf 'path: %s\n' "${path}"
        if [[ ! -d "${path}" ]]; then
            printf 'git_worktree: missing-directory\n'
        elif git -C "${path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            printf 'git_worktree: yes\n'
            printf 'head: '
            git -C "${path}" rev-parse HEAD
            printf 'describe: '
            git -C "${path}" describe --tags --always --dirty || true
            printf 'branch: '
            git -C "${path}" branch --show-current || true
            printf 'status:\n'
            git -C "${path}" status --porcelain=v1 --untracked-files=normal || true
            printf 'submodules:\n'
            git -C "${path}" submodule status --recursive || true
            printf 'remotes (sanitized):\n'
            while IFS= read -r remote; do
                url="$(git -C "${path}" remote get-url "${remote}" 2>/dev/null || true)"
                printf '%s ' "${remote}"
                printf '%s\n' "${url}" | sanitize_url
            done < <(git -C "${path}" remote)
        else
            printf 'git_worktree: no\n'
        fi
    } >"${identity}" 2>&1
    record_tree_manifest "${path}" "${stage}/${prefix}/tree-SHA256SUMS"
    record_tree_archive_hash "${path}" "${stage}/${prefix}/deterministic-tree.sha256"
}

record_process_library_map() {
    local service="$1"
    local prefix="$2"
    local pid
    pid="$(systemctl --user show -p MainPID --value "${service}" 2>/dev/null || true)"
    {
        printf 'service: %s\n' "${service}"
        printf 'main_pid: %s\n' "${pid}"
        if [[ "${pid}" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/maps" ]]; then
            grep -E '/[^[:space:]]*(libpiper_phonemize|libonnxruntime|libespeak-ng|libucd)[^[:space:]]*' \
                "/proc/${pid}/maps" | awk '{ print $NF }' | sort -u
        else
            printf 'INCOMPLETE: readable active-process library map unavailable\n'
        fi
    } >"${stage}/${prefix}/active-library-map.txt" 2>&1 || true

    while IFS= read -r library; do
        [[ "${library}" == /* && -f "${library}" ]] || continue
        sha256sum "${library}"
    done < <(grep '^/' "${stage}/${prefix}/active-library-map.txt" 2>/dev/null) \
        >"${stage}/${prefix}/active-library-SHA256SUMS" 2>&1 || true
}

sanitize_cache() {
    local input="$1"
    local output="$2"
    if [[ ! -f "${input}" ]]; then
        printf 'MISSING: %s\n' "${input}" >"${output}"
        return
    fi
    awk '
        {
            lower = tolower($0)
            if (lower ~ /(password|secret|token|api[_-]?key|authorization|cookie|credential)[[:space:]]*[:=]/) {
                print "# REDACTED sensitive configuration line"
            } else {
                print
            }
        }
    ' "${input}" >"${output}"
}

assert_stage_contract() {
    local invalid="${stage}/integrity/invalid-paths.txt"
    local links="${stage}/integrity/symlinks.txt"
    find "${stage}" -type l -printf '%P\n' | LC_ALL=C sort >"${links}"
    if [[ -s "${links}" ]]; then
        die "Staging tree contains symlinks; refusing to archive"
    fi
    find "${stage}" -type f -printf '%P\n' | LC_ALL=C sort | \
        awk '!/^(meta|services|dawn|piper|models|build|adapter|integrity)\// && $0 != "report.md" { print }' \
        >"${invalid}"
    if [[ -s "${invalid}" ]]; then
        die "Staging tree contains paths outside the declared allowlist"
    fi
}

scan_sensitive_values() {
    local keys="${stage}/integrity/sensitive-key-scan.txt"
    local signatures="${stage}/integrity/token-signature-scan.txt"
    grep -RInE --binary-files=without-match -i \
        '(password|secret|token|api[_-]?key|authorization|cookie|credential)[[:space:]]*[:=]' \
        "${stage}" >"${keys}" 2>&1 || true
    grep -RInE --binary-files=without-match \
        '(gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|DAWN-[A-Z0-9-]{12,})' \
        "${stage}" >"${signatures}" 2>&1 || true
    if [[ -s "${keys}" || -s "${signatures}" ]]; then
        die "Sensitive-value scan failed; capture archive was not created"
    fi
}

write_allowlist() {
    cat >"${stage}/integrity/allowlist.txt" <<'EOF'
# Paths permitted inside this audit archive
meta/
services/
dawn/
piper/
models/
build/
adapter/
integrity/
report.md
EOF
}

write_report() {
    cat >"${stage}/report.md" <<EOF
# Stage-3 WebUI/TTS/RKLLM Pilot Provenance Audit

- Capture time: $(date --iso-8601=seconds)
- Script mode: read-only evidence collection
- Captured adapter base: ${PROVENANCE_BASE}
- Archive model binaries: excluded

| Gate | Status | Note |
| --- | --- | --- |
| 0 — scope and safety | ${GATE_STATE[0]} | ${GATE_NOTE[0]} |
| 1 — DAWN, WebUI, and vendor provenance | ${GATE_STATE[1]} | ${GATE_NOTE[1]} |
| 2 — Piper and runtime loader closure | ${GATE_STATE[2]} | ${GATE_NOTE[2]} |
| 3 — model origin and identity | ${GATE_STATE[3]} | ${GATE_NOTE[3]} |
| 4 — CMake, toolchain, and dependency lock | ${GATE_STATE[4]} | ${GATE_NOTE[4]} |
| 5 — RKLLM adapter and test bootstrap | ${GATE_STATE[5]} | ${GATE_NOTE[5]} |
| 6 — secret safety and audit integrity | ${GATE_STATE[6]} | ${GATE_NOTE[6]} |

An INCOMPLETE gate is evidence of a remaining rebuild blocker. It is not a
failure of the active pilot and must not be papered over by inference.
EOF
}

if (( $# != 0 )); then
    die "This audit accepts no arguments"
fi

for command in awk basename cat cmake date dpkg-query find git grep head ldd mkdir \
    mktemp mv patch readelf readlink rm sed sha256sum sort ss stat strings systemctl tar tr uname xargs; do
    require_command "${command}"
done

[[ -d "${CAPTURE_ROOT}" && -w "${CAPTURE_ROOT}" ]] || die "Capture root is unavailable or not writable: ${CAPTURE_ROOT}"
service_is_active "${RKLLM_SERVICE}" || die "RKLLM user service is not active; refusing audit"
service_is_active "${WEBUI_SERVICE}" || die "WebUI/TTS user service is not active; refusing audit"

stage="$(mktemp -d "${CAPTURE_ROOT}/.pilot-provenance-audit.XXXXXX")"
mkdir -p "${stage}"/{meta,services,dawn,piper,models,build,adapter,integrity}

printf 'capture_started: %s\n' "$(date --iso-8601=seconds)" >"${stage}/meta/capture.txt"
printf 'capture_root: %s\n' "${CAPTURE_ROOT}" >>"${stage}/meta/capture.txt"
record_hash "$0" "${stage}/meta/audit-runner.sha256"
capture_cmd meta/os-release.txt cat /etc/os-release
capture_cmd meta/kernel-and-architecture.txt uname -a
capture_cmd meta/toolchain.txt bash -c 'cc --version; printf "\n--- c++ ---\n"; c++ --version; printf "\n--- cmake ---\n"; cmake --version; printf "\n--- linker ---\n"; ld --version | head -1; printf "\n--- pkg-config ---\n"; pkg-config --version 2>/dev/null || true'
capture_cmd meta/apt-sources.txt bash -c 'grep -RhsE "^[[:space:]]*deb " /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | sed -E "s#(https?|ssh)://[^/@[:space:]]+@#\\1://<redacted>@#g" | LC_ALL=C sort -u'
capture_cmd meta/relevant-packages.txt bash -c "dpkg-query -W -f='\${db:Status-Abbrev} \${Package} \${Version} \${Architecture}\\n' \"build-essential\" \"cmake\" \"ninja-build\" \"pkg-config\" \"git\" \"git-lfs\" \"libcurl*\" \"libespeak-ng*\" \"libflac*\" \"libjson-c*\" \"libmosquitto*\" \"libopus*\" \"libsndfile*\" \"libsodium*\" \"libspdlog*\" \"libsqlite3*\" \"libssl*\" \"libsamplerate*\" \"libwebsockets*\" 2>&1 | LC_ALL=C sort"

capture_cmd services/pre-service-state.txt bash -c 'systemctl --user is-active aibrain-rkllm.service; systemctl --user is-active dawn-stage3-webui-tts.service; ss -ltnH | awk "\\$4 == \"127.0.0.1:8081\" || \\$4 == \"127.0.0.1:3000\""'
capture_cmd services/rkllm-unit-safe-fields.txt bash -c 'systemctl --user show aibrain-rkllm.service -p MainPID -p WorkingDirectory -p ExecStart; systemctl --user show aibrain-rkllm.service -p Environment --value | tr " " "\\n" | grep -E "^(AIBRAIN_RKLLM_LIBRARY=|AIBRAIN_RKLLM_MODEL=)" || true'
capture_cmd services/webui-unit-safe-fields.txt bash -c 'systemctl --user show dawn-stage3-webui-tts.service -p MainPID -p WorkingDirectory -p ExecStart -p Environment | tr " " "\\n" | grep -E "^(MainPID|WorkingDirectory|ExecStart|LD_LIBRARY_PATH=|DAWN_TTS_ESPEAK_DATA_PATH=)" || true'
capture_cmd services/dawn-config-safe-fields.txt bash -c "if [ -f \"${DAWN_CONFIG}\" ]; then grep -nE '^[[:space:]]*(max_tokens|model|endpoint|enabled|bind_address|port|max_clients|www_path|https|data_dir|engine|models_path|voice_model|length_scale)[[:space:]]*=' \"${DAWN_CONFIG}\" || true; else echo MISSING: ${DAWN_CONFIG}; fi"

record_git_identity "${DAWN_SOURCE}" dawn/source
record_tree_manifest "${DAWN_SOURCE}/www" "${stage}/dawn/www-tree-SHA256SUMS"
record_tree_archive_hash "${DAWN_SOURCE}/www" "${stage}/dawn/www-deterministic-tree.sha256"
record_git_identity "${DAWN_SOURCE}/whisper.cpp" dawn/whispercpp
record_hash "${FEATURE_PATCH}" "${stage}/dawn/webui-feature-gating-patch.sha256"
capture_cmd dawn/webui-feature-gating-reverse-dry-run.txt bash -c "if [ -f \"${FEATURE_PATCH}\" ] && [ -d \"${DAWN_SOURCE}\" ]; then patch --dry-run --forward -R -d \"${DAWN_SOURCE}\" -p1 < \"${FEATURE_PATCH}\"; else echo INCOMPLETE: feature-gating patch or DAWN source missing; fi"
for patch_file in \
    "${PATCH_ROOT}/dawn-stage3-tts-text-cleanup-gate.patch" \
    "${PATCH_ROOT}/dawn-stage3-tts-private-espeak-path.patch" \
    "${PATCH_ROOT}/aibrain-rkllm-max-tokens-768-test.patch" \
    "${PATCH_ROOT}/aibrain-rkllm-message-context-20260820-124936.patch"; do
    record_hash "${patch_file}" "${stage}/dawn/patch-$(basename "${patch_file}").sha256"
done
capture_cmd dawn/accepted-source-markers.txt bash -c "grep -nE 'WHISPER_SAMPLING_BEAM_SEARCH|beam_size' \"${DAWN_SOURCE}/common/src/asr/asr_whisper.c\" 2>/dev/null | head -20; grep -n 'DAWN_TTS_ESPEAK_DATA_PATH' \"${DAWN_SOURCE}/src/tts/text_to_speech.cpp\" 2>/dev/null || true"
capture_cmd dawn/rejected-finish-reason-exclusion.txt bash -c "grep -nE 'finish_reason|MAX_NEW_TOKENS' \"${RKLLM_APP}/src/aibrain_rkllm/service.py\" 2>/dev/null || true; printf '\\nRejected finish-reason implementation: excluded from this audit and from the frozen pilot.\\n'"

record_git_identity "${PIPER_SOURCE}" piper/source
capture_cmd piper/configure-cache.txt bash -c "if [ -f \"${PIPER_BUILD}/CMakeCache.txt\" ]; then awk 'tolower(\$0) ~ /(password|secret|token|api[_-]?key|authorization|cookie|credential)[[:space:]]*[:=]/ { print \"# REDACTED sensitive configuration line\"; next } { print }' \"${PIPER_BUILD}/CMakeCache.txt\"; else echo MISSING: ${PIPER_BUILD}/CMakeCache.txt; fi"
capture_cmd piper/header-wiring.txt bash -c "for path in /srv/aibrain/test/deps/include/piper-phonemize \"${PIPER_SOURCE}/src\"; do printf 'path: %s\\n' \"\$path\"; readlink -f \"\$path\" 2>/dev/null || true; done; find /srv/aibrain/test/deps/include -maxdepth 2 -type f -name phonemize.hpp -exec sha256sum {} \\; 2>/dev/null || true"
capture_cmd piper/private-espeak-data-SHA256SUMS.txt bash -c "if [ -d \"${PIPER_BUILD}/ei/share/espeak-ng-data\" ]; then cd \"${PIPER_BUILD}/ei/share/espeak-ng-data\" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum; else echo MISSING: private eSpeak data directory; fi"
record_hash "${PIPER_BUILD}/libpiper_phonemize.so" "${stage}/piper/libpiper_phonemize.so.sha256"
record_hash "${PIPER_SOURCE}/lib/onnxruntime-linux-aarch64-1.14.1/lib/libonnxruntime.so" "${stage}/piper/libonnxruntime.so.sha256"
record_hash "${PIPER_BUILD}/ei/lib/libespeak-ng.so" "${stage}/piper/libespeak-ng.so.sha256"
record_tree_manifest "${PIPER_SOURCE}/lib/onnxruntime-linux-aarch64-1.14.1/include" "${stage}/piper/onnxruntime-include-SHA256SUMS"
capture_cmd piper/readelf-loader-metadata.txt bash -c "for library in \"${PIPER_BUILD}/libpiper_phonemize.so\" \"${PIPER_SOURCE}/lib/onnxruntime-linux-aarch64-1.14.1/lib/libonnxruntime.so\" \"${PIPER_BUILD}/ei/lib/libespeak-ng.so\"; do echo === \"\$library\" ===; readelf -d \"\$library\" 2>&1 | grep -E '(NEEDED|RPATH|RUNPATH|SONAME)' || true; done"
capture_cmd piper/onnx-espeak-origin-status.txt bash -c "printf 'ONNX Runtime public-header root: %s\\n' \"${PIPER_SOURCE}/lib/onnxruntime-linux-aarch64-1.14.1/include\"; printf 'eSpeak bundle root: %s\\n' \"${PIPER_BUILD}/ei\"; printf 'Immutable download/source provenance remains a review requirement unless present in the Piper Git metadata or CMake cache.\\n'"
record_process_library_map "${WEBUI_SERVICE}" services

webui_env="$(systemctl --user show "${WEBUI_SERVICE}" -p Environment --value 2>/dev/null || true)"
webui_ld_path="$(printf '%s\n' "${webui_env}" | tr ' ' '\n' | sed -n 's/^LD_LIBRARY_PATH=//p' | head -n1)"
{
    printf 'LD_LIBRARY_PATH: %s\n' "${webui_ld_path}"
    if [[ -n "${webui_ld_path}" && -f "${DAWN_BINARY}" ]]; then
        LD_LIBRARY_PATH="${webui_ld_path}" ldd "${DAWN_BINARY}"
    else
        printf 'INCOMPLETE: service library path or DAWN binary unavailable\n'
    fi
} >"${stage}/services/dawn-environment-aware-ldd.txt" 2>&1 || true
capture_cmd build/dawn-readelf-loader-metadata.txt bash -c "readelf -d \"${DAWN_BINARY}\" 2>&1 | grep -E '(NEEDED|RPATH|RUNPATH|SONAME)' || true"

record_hash "${RKLLM_MODEL}" "${stage}/models/rkllm-artifact.sha256"
record_hash "${WHISPER_MODEL}" "${stage}/models/whisper-small-en.sha256"
record_hash "${ALAN_MODEL}" "${stage}/models/alan-onnx.sha256"
record_hash "${ALAN_JSON}" "${stage}/models/alan-json.sha256"
record_hash "${RKLLM_LIBRARY}" "${stage}/models/librkllmrt.sha256"
capture_cmd models/alan-lfs-provenance.txt bash -c 'if [ -d /srv/aibrain/test/AI-clean-slate-assets/.git ]; then git -C /srv/aibrain/test/AI-clean-slate-assets rev-parse HEAD; git -C /srv/aibrain/test/AI-clean-slate-assets remote -v | sed -E "s#(https?|ssh)://[^/@[:space:]]+@#\\1://<redacted>@#g"; git -C /srv/aibrain/test/AI-clean-slate-assets lfs ls-files 2>/dev/null | grep -E "en_GB-alan-medium" || true; else echo INCOMPLETE: Alan asset checkout metadata unavailable; fi'
capture_cmd models/origin-status.txt bash -c 'cat <<"EOF"
Whisper small.en: identity captured; immutable origin must be confirmed from a pinned release URL plus content hash.
Alan assets: Git/LFS metadata captured when present; immutable checkout reference requires review.
RKLLM artifact: identity captured; conversion lineage, source-model identity, toolkit version, and options remain required unless separately documented.
Model binaries are intentionally excluded from this audit archive.
EOF'
capture_cmd models/rkllm-runtime-metadata.txt bash -c "for file in \"${RKLLM_LIBRARY}\" \"${RKLLM_MODEL}\"; do echo === \"\$file\" ===; strings -a \"\$file\" 2>/dev/null | grep -iE 'rkllm.*(runtime|toolkit|version)|version.*rkllm' | head -40 || true; done"

record_hash "${DAWN_BUILD}/CMakeCache.txt" "${stage}/build/dawn-CMakeCache-raw.sha256"
sanitize_cache "${DAWN_BUILD}/CMakeCache.txt" "${stage}/build/dawn-CMakeCache-sanitized.txt"
capture_cmd build/dawn-link-commands.txt bash -c "find \"${DAWN_BUILD}\" -type f -path '*/CMakeFiles/dawn.dir/link.txt' -print -exec cat {} \\; 2>/dev/null"
capture_cmd build/dawn-compile-flags.txt bash -c "find \"${DAWN_BUILD}\" -type f -path '*/CMakeFiles/dawn.dir/flags.make' -print -exec cat {} \\; 2>/dev/null"
record_hash "${DAWN_BINARY}" "${stage}/build/dawn-binary.sha256"

record_git_identity "${RKLLM_APP}" adapter/source
capture_cmd adapter/accepted-local-diff.txt bash -c "git -C \"${RKLLM_APP}\" diff -- src/aibrain_rkllm/service.py tests/test_service.py 2>/dev/null || true"
record_hash "${RKLLM_APP}/src/aibrain_rkllm/service.py" "${stage}/adapter/service.py.sha256"
record_hash "${RKLLM_APP}/tests/test_service.py" "${stage}/adapter/test_service.py.sha256"
capture_cmd adapter/python-and-packages.txt bash -c '/srv/aibrain/production/runtime/rkllm-venv/bin/python3 --version; /srv/aibrain/production/runtime/rkllm-venv/bin/python3 -m pip freeze 2>/dev/null || true; /srv/aibrain/production/runtime/rkllm-venv/bin/python3 -c "import importlib.util; print(\"pytest_available=\", importlib.util.find_spec(\"pytest\") is not None)"'
capture_cmd adapter/test-bootstrap-metadata.txt bash -c "for file in pyproject.toml setup.cfg setup.py requirements*.txt; do [ -f \"${RKLLM_APP}/\$file\" ] || continue; echo === \$file ===; sed -n '1,260p' \"${RKLLM_APP}/\$file\"; done"
capture_cmd adapter/dependency-free-test-run.txt bash -c 'PYTHONDONTWRITEBYTECODE=1 /srv/aibrain/production/runtime/rkllm-venv/bin/python3 - /srv/aibrain/production/apps/AI_Brain_Build/tests/test_service.py <<"PY"
import runpy
import sys

tests = runpy.run_path(sys.argv[1])
for name in sorted(key for key in tests if key.startswith("test_")):
    tests[name]()
    print(f"PASS {name}")
PY'

if service_is_active "${RKLLM_SERVICE}" && service_is_active "${WEBUI_SERVICE}" && \
    loopback_listener_present 8081 && loopback_listener_present 3000; then
    gate 0 PASS 'Both active user services remained active and both endpoints remained loopback-bound during the audit.'
else
    gate 0 INCOMPLETE 'A required service state or loopback listener was not observed; no remediation was attempted.'
fi

if git -C "${DAWN_SOURCE}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
    git -C "${DAWN_SOURCE}/whisper.cpp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gate 1 PASS 'Git identities, frontend/vendor manifests, and accepted patch evidence were captured.'
else
    gate 1 INCOMPLETE 'The active DAWN source and/or vendored whisper.cpp is not tied to a captured immutable Git identity; manifests are evidence only.'
fi

if grep -q '^/' "${stage}/services/active-library-map.txt" 2>/dev/null && \
    ! grep -q 'not found' "${stage}/services/dawn-environment-aware-ldd.txt" 2>/dev/null; then
    gate 2 INCOMPLETE 'Runtime library paths were captured, but full Piper/ONNX/eSpeak artifact origin and build provenance still require review.'
else
    gate 2 INCOMPLETE 'The environment-aware library closure is not fully evidenced; inspect loader and active-process evidence.'
fi

gate 3 INCOMPLETE 'Model identities were hashed, but immutable Whisper/Alan origins and RKLLM conversion lineage require review.'
gate 4 INCOMPLETE 'Build cache, toolchain, package, and loader evidence were captured; a complete dependency lock is not yet established.'
if grep -q 'pytest_available= True' "${stage}/adapter/python-and-packages.txt" 2>/dev/null; then
    gate 5 INCOMPLETE 'Adapter state and test metadata were captured; a pinned, reproducible test bootstrap still requires review.'
else
    gate 5 INCOMPLETE 'Current environment lacks pytest or does not expose it; dependency-free test output is pilot evidence only.'
fi

gate 6 INCOMPLETE 'Integrity scan pending.'
write_allowlist
assert_stage_contract
write_report
scan_sensitive_values
gate 6 PASS 'Staged paths matched the allowlist, no symlinks were present, and both sensitive-value scans were empty.'
write_report
scan_sensitive_values
manifest_tmp="${CAPTURE_ROOT}/.pilot-provenance-audit-manifest.$$.tmp"
(
    cd "${stage}" || exit 1
    find . -type f ! -path './integrity/SHA256SUMS' ! -path './integrity/manifest-verification.txt' -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
) >"${manifest_tmp}"
mv -- "${manifest_tmp}" "${stage}/integrity/SHA256SUMS"
(cd "${stage}" && sha256sum -c integrity/SHA256SUMS) >"${stage}/integrity/manifest-verification.txt" 2>&1 || die "Relative-path manifest verification failed"
scan_sensitive_values

capture_finished="$(date +%Y%m%d-%H%M%S)"
archive="${CAPTURE_ROOT}/pilot-provenance-audit-${capture_finished}.tar.gz"
tar -C "${stage}" -czf "${archive}" .
tar -tzf "${archive}" >/dev/null || die "Archive integrity check failed"
archive_hash="$(sha256sum "${archive}" | awk '{print $1}')"

printf 'PASS: sanitized provenance audit created.\n'
printf 'Archive: %s\n' "${archive}"
printf 'Archive SHA-256: %s\n' "${archive_hash}"
printf 'Review report: tar -xOzf %q ./report.md\n' "${archive}"
