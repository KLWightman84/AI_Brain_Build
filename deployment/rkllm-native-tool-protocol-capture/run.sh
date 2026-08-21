#!/usr/bin/env bash
# Read-only capture for diagnosing DAWN native-tool calling through the RKLLM
# adapter. It deliberately collects source and source hashes only: no configs,
# credentials, service environments, model files, or conversation logs.
set -Eeuo pipefail
umask 077

APP=/srv/aibrain/production/apps/AI_Brain_Build
DAWN_SRC=/srv/aibrain/test/builds/dawn-stage3-source
CAPTURES=/srv/aibrain/test/captures
STAMP=$(date +%Y%m%d-%H%M%S)
STAGE=$(mktemp -d "$CAPTURES/.rkllm-native-tool-protocol.XXXXXX")
ARCHIVE="$CAPTURES/rkllm-native-tool-protocol-$STAMP.tar.gz"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

collect() {
  local source=$1
  local relative=$2
  [ -f "$source" ] || fail "Required source file is missing: $source"
  mkdir -p "$STAGE/source/$(dirname "$relative")"
  cp "$source" "$STAGE/source/$relative"
  sha256sum "$source" >>"$STAGE/source-SHA256SUMS.txt"
}

collect_optional() {
  local source=$1
  local relative=$2
  if [ -f "$source" ]; then
    collect "$source" "$relative"
  else
    printf 'optional source absent: %s\n' "$source" >>"$STAGE/optional-absent.txt"
  fi
}

mkdir -p "$CAPTURES"
[ -d "$APP" ] || fail "RKLLM adapter root is missing: $APP"
[ -d "$DAWN_SRC" ] || fail "DAWN source root is missing: $DAWN_SRC"

# Adapter boundary: request construction, native inference, and SSE rendering.
collect "$APP/src/aibrain_rkllm/service.py" "rkllm/service.py"
collect "$APP/src/aibrain_rkllm/wsgi_factory.py" "rkllm/wsgi_factory.py"
collect "$APP/src/aibrain_rkllm/inference.py" "rkllm/inference.py"
collect "$APP/src/aibrain_rkllm/protocol.py" "rkllm/protocol.py"
collect "$APP/tests/test_service.py" "rkllm/tests/test_service.py"

# DAWN side: tool instruction construction, parsing, execution, and SSE path.
collect "$DAWN_SRC/src/llm/llm_command_parser.c" "dawn/src/llm/llm_command_parser.c"
collect "$DAWN_SRC/src/llm/llm_tools.c" "dawn/src/llm/llm_tools.c"
collect "$DAWN_SRC/src/llm/llm_tool_loop.c" "dawn/src/llm/llm_tool_loop.c"
collect "$DAWN_SRC/src/llm/llm_openai_chat_completions.c" "dawn/src/llm/llm_openai_chat_completions.c"
collect "$DAWN_SRC/src/llm/llm_streaming.c" "dawn/src/llm/llm_streaming.c"
collect "$DAWN_SRC/src/llm/llm_openai_history.c" "dawn/src/llm/llm_openai_history.c"
collect_optional "$DAWN_SRC/include/llm/llm_tools.h" "dawn/include/llm/llm_tools.h"
collect_optional "$DAWN_SRC/include/llm/llm_tool_loop.h" "dawn/include/llm/llm_tool_loop.h"
collect_optional "$DAWN_SRC/include/llm/llm_interface.h" "dawn/include/llm/llm_interface.h"

{
  printf 'kind=rkllm_native_tool_protocol_capture\n'
  printf 'captured_at_utc=%s\n' "$STAMP"
  printf 'adapter_git_head='
  git -C "$APP" rev-parse HEAD 2>/dev/null || printf 'unavailable\n'
  printf 'scope=source_and_hashes_only\n'
  printf 'exclusions=configs,credentials,service-environments,models,logs,conversation-data\n'
} >"$STAGE/manifest.txt"

grep -RniE \
  'native tool|tool.?call|tool_calls|function.?call|<tool|</tool|tools? mode|stream' \
  "$STAGE/source" >"$STAGE/protocol-reference-map.txt" || true

# Fail closed rather than archive accidental credential material.
if grep -RInE \
  '(gho_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|DAWN-[A-Z0-9-]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' \
  "$STAGE" >/dev/null; then
  fail "Sensitive-value scan failed; capture archive was not created"
fi

tar -C "$STAGE" -czf "$ARCHIVE" .
printf '%s\n' 'PASS: RKLLM/DAWN native-tool protocol source capture created.'
printf 'Archive: %s\n' "$ARCHIVE"
printf 'Archive SHA-256: %s\n' "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf 'Review map: tar -xOzf %s ./protocol-reference-map.txt\n' "$ARCHIVE"
