#!/usr/bin/env bash
# Read-only evidence capture for the tokenizer prerequisite to RKLLM context budgeting.
#
# This is deliberately NOT an installer.  It neither changes source/configuration nor
# restarts any service.  A captured tokenizer candidate is evidence only: it is not
# considered usable until its lineage and behavior are certified against the active
# RKLLM artifact.

set -euo pipefail
umask 077

CAPTURE_ROOT="${AIBRAIN_CAPTURE_ROOT:-/srv/aibrain/test/captures}"
RKLLM_APP="${AIBRAIN_RKLLM_APP:-/srv/aibrain/production/apps/AI_Brain_Build}"
RKLLM_SERVICE="${AIBRAIN_RKLLM_SERVICE:-aibrain-rkllm.service}"
RKLLM_MODEL="${AIBRAIN_RKLLM_MODEL:-/srv/aibrain/production/models/Qwen3.5-4B_w8a8_rk3588_ctx4096.rkllm}"
RKLLM_PORT="${AIBRAIN_RKLLM_PORT:-8081}"
SCAN_ROOTS="${AIBRAIN_TOKENIZER_SCAN_ROOTS:-/srv/aibrain/production/models:/srv/aibrain/production/apps/AI_Brain_Build:/srv/aibrain/forensic:/srv/aibrain/test}"

stage=""
archive=""
secret_hits=""
declare -a scan_roots=()

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

cleanup() {
    if [[ -n "${secret_hits}" && -f "${secret_hits}" ]]; then
        case "${secret_hits}" in
            "${CAPTURE_ROOT}"/.tokenizer-lineage-secret-scan.*) rm -f -- "${secret_hits}" ;;
        esac
    fi
    if [[ -n "${stage}" && -d "${stage}" ]]; then
        case "${stage}" in
            "${CAPTURE_ROOT}"/.tokenizer-lineage-capture.*) rm -rf -- "${stage}" ;;
        esac
    fi
}
trap cleanup EXIT

listener_is_loopback_only() {
    local port="$1"
    local listeners
    listeners="$(ss -ltnH 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" { print $4 }')"
    [[ -n "${listeners}" ]] || return 1
    while IFS= read -r listener; do
        [[ "${listener}" == "127.0.0.1:${port}" || "${listener}" == "[::1]:${port}" ]] || return 1
    done <<<"${listeners}"
}

sanitize_url() {
    sed -E 's#(https?|ssh)://[^/@[:space:]]+@#\1://<redacted>@#g'
}

record_file_identity() {
    local path="$1"
    local output="$2"
    local resolved

    mkdir -p "$(dirname "${output}")"
    {
        printf 'path: %s\n' "${path}"
        if [[ -L "${path}" ]]; then
            printf 'file_type: symlink\n'
            printf 'link_target: %s\n' "$(readlink -- "${path}")"
            printf 'link_bytes: %s\n' "$(readlink -- "${path}" | LC_ALL=C wc -c)"
            resolved="$(readlink -f -- "${path}" 2>/dev/null || true)"
            if [[ -z "${resolved}" || ! -f "${resolved}" ]]; then
                printf 'resolved_target: MISSING\n'
                return
            fi
            printf 'resolved_target: %s\n' "${resolved}"
            stat -Lc 'resolved_bytes: %s' "${path}"
            printf 'resolved_sha256: '
            sha256sum -- "${path}" | awk '{ print $1 }'
        elif [[ -f "${path}" ]]; then
            printf 'file_type: regular\n'
            stat -Lc 'bytes: %s' "${path}"
            printf 'sha256: '
            sha256sum -- "${path}" | awk '{ print $1 }'
        else
            printf 'MISSING\n'
        fi
    } >"${output}"
}

record_git_identity() {
    local path="$1"
    local output="$2"
    mkdir -p "$(dirname "${output}")"
    {
        printf 'path: %s\n' "${path}"
        if [[ ! -d "${path}" ]]; then
            printf 'git_worktree: missing-directory\n'
        elif git -C "${path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            printf 'git_worktree: yes\n'
            printf 'head: '
            git -C "${path}" rev-parse HEAD
            printf 'describe: '
            git -C "${path}" describe --always --tags --dirty || true
            printf 'remotes (sanitized):\n'
            while IFS= read -r remote; do
                printf '%s ' "${remote}"
                git -C "${path}" remote get-url "${remote}" 2>/dev/null | sanitize_url
            done < <(git -C "${path}" remote)
        else
            printf 'git_worktree: no\n'
        fi
    } >"${output}" 2>&1
}

candidate_find_expression() {
    find "$1" -xdev \( -type f -o -type l \) \( \
        -iname 'tokenizer.json' -o \
        -iname 'tokenizer_config.json' -o \
        -iname 'special_tokens_map.json' -o \
        -iname 'added_tokens.json' -o \
        -iname 'vocab.json' -o \
        -iname 'merges.txt' -o \
        -iname '*.tiktoken' -o \
        -iname 'spiece.model' -o \
        -iname 'sentencepiece.model' \
    \) -print0 2>/dev/null
}

collect_candidates() {
    local list_output="${stage}/tokenizer/candidates.list"
    local manifest_output="${stage}/tokenizer/candidate-identities.txt"
    local root path count=0

    : >"${list_output}"
    for root in "${scan_roots[@]}"; do
        [[ -d "${root}" ]] || continue
        candidate_find_expression "${root}" >>"${list_output}"
    done
    LC_ALL=C sort -zu "${list_output}" -o "${list_output}"

    {
        printf '# Tokenizer asset candidates. Presence alone does not certify compatibility.\n'
        printf '# Matching requires a conversion-lineage record and runtime prefill validation.\n\n'
    } >"${manifest_output}"
    while IFS= read -r -d '' path; do
        count=$((count + 1))
        printf '[candidate %d]\n' "${count}" >>"${manifest_output}"
        record_file_identity "${path}" "${stage}/tokenizer/.identity-${count}.txt"
        cat "${stage}/tokenizer/.identity-${count}.txt" >>"${manifest_output}"
        rm -f -- "${stage}/tokenizer/.identity-${count}.txt"
        printf '\n' >>"${manifest_output}"
    done <"${list_output}"

    printf '%d\n' "${count}" >"${stage}/tokenizer/candidate-count.txt"
}

collect_adapter_contract() {
    local output="${stage}/adapter/tokenizer-contract.txt"
    local rel path
    local -a files=(
        'src/aibrain_rkllm/service.py'
        'src/aibrain_rkllm/inference.py'
        'src/aibrain_rkllm/model.py'
        'src/aibrain_rkllm/native.py'
        'src/aibrain_rkllm/protocol.py'
    )

    {
        printf '# Static adapter contract evidence; no source content is copied.\n\n'
        for rel in "${files[@]}"; do
            path="${RKLLM_APP}/${rel}"
            printf '[%s]\n' "${rel}"
            if [[ -f "${path}" ]]; then
                printf 'sha256: '
                sha256sum -- "${path}" | awk '{ print $1 }'
                grep -nE 'TokenizerCallback|tokenizer_callback|rkllm_tokenize|prefill_tokens|keep_history|max_new_tokens|RKLLM_INPUT_TOKEN' \
                    "${path}" || true
            else
                printf 'MISSING\n'
            fi
            printf '\n'
        done
    } >"${output}" 2>&1
}

collect_lineage_hints() {
    local output="${stage}/lineage/reference-files.txt"
    local root
    : >"${output}"
    for root in "${scan_roots[@]}"; do
        [[ -d "${root}" ]] || continue
        find "${root}" -xdev -type f \( \
            -iname '*rkllm*' -o -iname '*qwen*' -o -iname '*convert*' -o -iname '*tokenizer*' \
        \) \
            ! -iname '*.rkllm' ! -iname '*.gguf' ! -iname '*.bin' ! -iname '*.onnx' \
            ! -path '*/__pycache__/*' \
            -printf '%p\n' 2>/dev/null || true
    done | LC_ALL=C sort -u | while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        printf 'path: %s\n' "${path}"
        printf 'sha256: '
        sha256sum -- "${path}" | awk '{ print $1 }'
    done >"${output}"
}

scan_generated_for_secrets() {
    local file match
    secret_hits="$(mktemp "${CAPTURE_ROOT}/.tokenizer-lineage-secret-scan.XXXXXX")"
    : >"${secret_hits}"
    while IFS= read -r -d '' file; do
        while IFS= read -r match; do
            printf '%s\n' "${file}" >>"${secret_hits}"
        done < <(grep -Ein '(password|secret|api[_-]?key|authorization|cookie|credential)[[:space:]]*[:=]' "${file}" || true)
    done < <(find "${stage}" -type f -print0)
    if [[ -s "${secret_hits}" ]]; then
        printf 'ERROR: Sensitive-value scan failed; capture archive was not created.\n' >&2
        return 1
    fi
}

write_report() {
    local candidate_count
    candidate_count="$(cat "${stage}/tokenizer/candidate-count.txt")"
    {
        printf '# RKLLM Tokenizer-Lineage Capture\n\n'
        printf 'This is a read-only prerequisite capture for exact token-aware context trimming.\n'
        printf 'It does not download, install, select, or certify a tokenizer.\n\n'
        printf '## Evidence\n\n'
        printf -- '- Active RKLLM model identity: `models/active-model.txt`\n'
        printf -- '- Adapter tokenizer contract: `adapter/tokenizer-contract.txt`\n'
        printf -- '- Candidate tokenizer assets: `tokenizer/candidate-identities.txt`\n'
        printf -- '- Conversion/model-lineage filename hints: `lineage/reference-files.txt`\n\n'
        printf '## Gates\n\n'
        printf '| Gate | Result | Interpretation |\n'
        printf '|---|---|---|\n'
        printf '| Active service and loopback listener | PASS | Capture reflects the live RKLLM service. |\n'
        printf '| Active model identity | PASS | Path, size, and SHA-256 were recorded without copying the model. |\n'
        printf '| Pre-inference tokenizer API | RECORDED | Static contract is evidence; undocumented RKLLM symbols must not be guessed. |\n'
        if [[ "${candidate_count}" == '0' ]]; then
            printf '| Model-matched tokenizer asset | UNRESOLVED | No candidate asset was found in the approved local scan roots. |\n'
        else
            printf '| Model-matched tokenizer asset | UNRESOLVED | %s candidate(s) found; lineage and behavior are not yet certified. |\n' "${candidate_count}"
        fi
        printf '| Native chat-envelope reserve | UNRESOLVED | Must be measured later with the selected tokenizer and RKLLM prefill telemetry. |\n\n'
        printf 'A future implementation may proceed only after an exact tokenizer revision/SHA-256 is tied to this model conversion and validated against RKLLM prefill counts.\n'
    } >"${stage}/report.md"
}

write_integrity_manifest() {
    (
        cd "${stage}"
        find . -type f ! -path './integrity/relative-SHA256SUMS' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
    ) >"${stage}/integrity/relative-SHA256SUMS"
}

archive_capture() {
    local stamp
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    archive="${CAPTURE_ROOT}/tokenizer-lineage-capture-${stamp}.tar.gz"
    tar -C "${stage}" -czf "${archive}" .
    printf 'PASS: tokenizer-lineage capture created.\n'
    printf 'Archive: %s\n' "${archive}"
    printf 'Archive SHA-256: %s\n' "$(sha256sum -- "${archive}" | awk '{ print $1 }')"
    printf 'Review report: tar -xOzf %q ./report.md\n' "${archive}"
}

capture() {
    local service_pid
    local IFS=':'

    require_command awk
    require_command find
    require_command grep
    require_command readlink
    require_command sha256sum
    require_command sort
    require_command ss
    require_command stat
    require_command systemctl
    require_command tar

    read -r -a scan_roots <<<"${SCAN_ROOTS}"
    [[ -d "${RKLLM_APP}" ]] || die "Required RKLLM application directory is missing: ${RKLLM_APP}"
    [[ -f "${RKLLM_MODEL}" || -L "${RKLLM_MODEL}" ]] || die "Required RKLLM model is missing: ${RKLLM_MODEL}"

    if [[ "${AIBRAIN_SKIP_SERVICE_CHECK:-0}" != '1' ]]; then
        systemctl --user is-active --quiet "${RKLLM_SERVICE}" || die "RKLLM service is not active: ${RKLLM_SERVICE}"
        listener_is_loopback_only "${RKLLM_PORT}" || die "RKLLM listener is missing or non-loopback on port ${RKLLM_PORT}"
    fi

    mkdir -p "${CAPTURE_ROOT}"
    stage="$(mktemp -d "${CAPTURE_ROOT}/.tokenizer-lineage-capture.XXXXXX")"
    mkdir -p "${stage}/adapter" "${stage}/integrity" "${stage}/lineage" "${stage}/meta" "${stage}/models" "${stage}/services" "${stage}/tokenizer"

    service_pid="$(systemctl --user show -p MainPID --value "${RKLLM_SERVICE}" 2>/dev/null || true)"
    {
        printf 'service: %s\n' "${RKLLM_SERVICE}"
        printf 'main_pid: %s\n' "${service_pid}"
        printf 'active: '
        systemctl --user is-active "${RKLLM_SERVICE}" 2>/dev/null || true
        printf 'listener: 127.0.0.1:%s\n' "${RKLLM_PORT}"
    } >"${stage}/services/rkllm-service.txt"
    printf 'runner_sha256: %s\n' "$(sha256sum -- "$0" | awk '{ print $1 }')" >"${stage}/meta/runner.txt"
    record_file_identity "${RKLLM_MODEL}" "${stage}/models/active-model.txt"
    record_git_identity "${RKLLM_APP}" "${stage}/adapter/git-identity.txt"
    collect_adapter_contract
    collect_candidates
    collect_lineage_hints
    write_report
    scan_generated_for_secrets || die 'Generated evidence may contain a sensitive value'
    write_integrity_manifest
    archive_capture
}

self_test() {
    local test_root
    local old_capture_root="${CAPTURE_ROOT}"
    local old_app="${RKLLM_APP}"
    local old_model="${RKLLM_MODEL}"
    local old_scan_roots="${SCAN_ROOTS}"
    local old_skip="${AIBRAIN_SKIP_SERVICE_CHECK:-0}"
    local report

    test_root="$(mktemp -d /tmp/tokenizer-lineage-capture-test.XXXXXX)"
    trap 'if [[ -n "${test_root:-}" ]]; then rm -rf -- "${test_root}"; fi; cleanup' EXIT
    mkdir -p "${test_root}/app/src/aibrain_rkllm" "${test_root}/models/source"
    printf 'class TokenizerCallback: pass\n' >"${test_root}/app/src/aibrain_rkllm/protocol.py"
    printf 'prefill_tokens = 0\nkeep_history = 0\n' >"${test_root}/app/src/aibrain_rkllm/inference.py"
    printf 'placeholder\n' >"${test_root}/app/src/aibrain_rkllm/service.py"
    printf 'placeholder\n' >"${test_root}/app/src/aibrain_rkllm/model.py"
    printf 'placeholder\n' >"${test_root}/app/src/aibrain_rkllm/native.py"
    printf 'model-data\n' >"${test_root}/models/model.rkllm"
    printf '{"version":"test"}\n' >"${test_root}/models/source/tokenizer.json"
    printf '{"bos_token":"<s>"}\n' >"${test_root}/models/source/tokenizer_config.json"

    CAPTURE_ROOT="${test_root}/captures"
    RKLLM_APP="${test_root}/app"
    RKLLM_MODEL="${test_root}/models/model.rkllm"
    SCAN_ROOTS="${test_root}/models:${test_root}/app"
    AIBRAIN_SKIP_SERVICE_CHECK=1
    capture

    report="$(find "${CAPTURE_ROOT}" -maxdepth 1 -name 'tokenizer-lineage-capture-*.tar.gz' -print -quit)"
    [[ -f "${report}" ]] || die 'Self-test did not create an archive'
    tar -xOzf "${report}" ./tokenizer/candidate-count.txt | grep -qx '2' || die 'Self-test candidate count mismatch'
    tar -xOzf "${report}" ./report.md | grep -Fq '2 candidate(s) found' || die 'Self-test report mismatch'

    rm -f -- "${test_root}/models/source/tokenizer.json" "${test_root}/models/source/tokenizer_config.json"
    CAPTURE_ROOT="${test_root}/captures-no-candidates"
    capture
    report="$(find "${CAPTURE_ROOT}" -maxdepth 1 -name 'tokenizer-lineage-capture-*.tar.gz' -print -quit)"
    [[ -f "${report}" ]] || die 'Self-test did not create a no-candidate archive'
    tar -xOzf "${report}" ./tokenizer/candidate-count.txt | grep -qx '0' || die 'Self-test no-candidate count mismatch'
    tar -xOzf "${report}" ./report.md | grep -Fq 'No candidate asset was found' || die 'Self-test no-candidate report mismatch'
    printf 'PASS: tokenizer-lineage capture self-test completed.\n'

    CAPTURE_ROOT="${old_capture_root}"
    RKLLM_APP="${old_app}"
    RKLLM_MODEL="${old_model}"
    SCAN_ROOTS="${old_scan_roots}"
    AIBRAIN_SKIP_SERVICE_CHECK="${old_skip}"
}

case "${1:-}" in
    '') capture ;;
    --self-test) self_test ;;
    *) die "Usage: $0 [--self-test]" ;;
esac
