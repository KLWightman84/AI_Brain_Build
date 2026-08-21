#!/usr/bin/env bash
# Installs a read-only DAWN maintenance inspection tool. It does not alter
# RKLLM, the DAWN persona/configuration, or the external maintenance policy.
set -Eeuo pipefail
umask 077

SOURCE=/srv/aibrain/test/builds/dawn-stage3-source
BUILD=/srv/aibrain/test/builds/dawn-stage3-webui-tts
DAWN="$BUILD/dawn"
SERVICE=dawn-stage3-webui-tts.service
BACKUPS=/srv/aibrain/test/backups
LOGS=/srv/aibrain/test/logs/webui
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUPS/dawn-maintenance-inspect-$STAMP"
LOG="$LOGS/dawn-maintenance-inspect-build-$STAMP.log"
TOOLS_INIT="$SOURCE/src/tools/tools_init.c"
CMAKE_FILE="$SOURCE/CMakeLists.txt"
TOOL_SOURCE="$SOURCE/src/tools/maintenance_inspect_tool.c"
TOOL_HEADER="$SOURCE/include/tools/maintenance_inspect_tool.h"
APPLIED=0

expected_tools_init=e9415db6ba6a24648322b126455ee31c4b10f46442a0b2eefc6cc68186718c65
expected_cmake=55f238c323e66a7a34968433583ac7a98e3f2d83777bd95da8eee11062e965a7
expected_tool_source=f7a1e3f8b61ca6e1ec83166e9a45a2019d544b175150488ce466a6c90877c0eb
expected_tool_header=6fdade34fde554105e62afe34f24f49ef5e7293df32a17d71d3cb89919b58eef
source_base=https://raw.githubusercontent.com/KLWightman84/AI_Brain_Build/4060ea7af9812a5a858648fc7042f5dbf92d71d4/deployment/dawn-maintenance-inspect-tool

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

rollback() {
  local code=$?
  trap - ERR
  if [ "$APPLIED" -eq 1 ]; then
    printf '%s\n' 'Restoring DAWN source and executable from this installer backup.' >&2
    cp "$BACKUP/tools_init.c" "$TOOLS_INIT"
    cp "$BACKUP/CMakeLists.txt" "$CMAKE_FILE"
    rm -f "$TOOL_SOURCE" "$TOOL_HEADER"
    cp "$BACKUP/dawn" "$DAWN"
    systemctl --user restart "$SERVICE" || true
  fi
  exit "$code"
}
trap rollback ERR

[ -d "$SOURCE" ] || fail "DAWN source is missing: $SOURCE"
[ -d "$BUILD" ] || fail "DAWN build directory is missing: $BUILD"
[ -x "$DAWN" ] || fail "DAWN executable is missing: $DAWN"
[ -f "$TOOLS_INIT" ] || fail "DAWN tool registration source is missing"
[ -f "$CMAKE_FILE" ] || fail "DAWN CMakeLists.txt is missing"
[ ! -e "$TOOL_SOURCE" ] || fail "maintenance_inspect source already exists; refusing to overwrite"
[ ! -e "$TOOL_HEADER" ] || fail "maintenance_inspect header already exists; refusing to overwrite"

actual=$(sha256sum "$TOOLS_INIT" | awk '{print $1}')
[ "$actual" = "$expected_tools_init" ] || fail "tools_init.c identity differs from the captured source"
actual=$(sha256sum "$CMAKE_FILE" | awk '{print $1}')
[ "$actual" = "$expected_cmake" ] || fail "CMakeLists.txt identity differs from the captured source"

mkdir -p "$BACKUP" "$LOGS"
cp -a "$TOOLS_INIT" "$BACKUP/tools_init.c"
cp -a "$CMAKE_FILE" "$BACKUP/CMakeLists.txt"
cp -a "$DAWN" "$BACKUP/dawn"
APPLIED=1

curl --fail --location --silent --show-error "$source_base/maintenance_inspect_tool.c" -o "$TOOL_SOURCE"
actual=$(sha256sum "$TOOL_SOURCE" | awk '{print $1}')
[ "$actual" = "$expected_tool_source" ] || fail "maintenance source payload checksum mismatch"
curl --fail --location --silent --show-error "$source_base/maintenance_inspect_tool.h" -o "$TOOL_HEADER"
actual=$(sha256sum "$TOOL_HEADER" | awk '{print $1}')
[ "$actual" = "$expected_tool_header" ] || fail "maintenance header payload checksum mismatch"

python3 - "$TOOLS_INIT" "$CMAKE_FILE" <<'PY'
from pathlib import Path
import sys

tools_init = Path(sys.argv[1])
cmake_file = Path(sys.argv[2])

needle = '#include "tools/attention_tool.h"\n'
replacement = needle + '#include "tools/maintenance_inspect_tool.h"\n'
text = tools_init.read_text()
if text.count(needle) != 1:
    raise SystemExit('expected attention include exactly once')
tools_init.write_text(text.replace(needle, replacement, 1))

needle = '''   if (attention_tool_register() != 0) {
      OLOG_WARNING("Failed to register attention tool");
   }
'''
replacement = needle + '''
   /* Maintenance inspection is a core, read-only diagnostic. It deliberately
    * has no command execution or repair capability. */
   if (maintenance_inspect_tool_register() != 0) {
      OLOG_WARNING("Failed to register maintenance_inspect tool");
   }
'''
text = tools_init.read_text()
if text.count(needle) != 1:
    raise SystemExit('expected attention registration exactly once')
tools_init.write_text(text.replace(needle, replacement, 1))

needle = '    src/tools/tools_init.c\n'
replacement = needle + '    src/tools/maintenance_inspect_tool.c\n'
text = cmake_file.read_text()
if text.count(needle) != 1:
    raise SystemExit('expected tools_init CMake source exactly once')
cmake_file.write_text(text.replace(needle, replacement, 1))
PY

if grep -nE '\b(system|popen|fork|vfork|execve?|posix_spawn|sudo)[[:space:]]*\(' "$TOOL_SOURCE"; then
  fail "native maintenance tool contains forbidden process-control code"
fi

if ! cmake --build "$BUILD" --parallel 4 >"$LOG" 2>&1; then
  tail -80 "$LOG" >&2 || true
  fail "DAWN build failed; see $LOG"
fi

systemctl --user restart "$SERVICE"
for _ in $(seq 1 60); do
  if systemctl --user is-active --quiet "$SERVICE" && \
     ss -ltnH | awk '$4 == "127.0.0.1:3000" { found = 1 } END { exit !found }'; then
    break
  fi
  sleep 1
done
systemctl --user is-active --quiet "$SERVICE" || fail "DAWN service did not become active"
ss -ltnH | awk '$4 == "127.0.0.1:3000" { found = 1 } END { exit !found }' || \
  fail "DAWN WebUI is not bound to 127.0.0.1:3000"
journalctl --user -u "$SERVICE" -n 300 --no-pager | \
  grep -F 'Registered tool: maintenance_inspect' >/dev/null || \
  fail "DAWN did not log maintenance_inspect registration"
curl -fsS http://127.0.0.1:8081/healthz | grep -F '"status":"ok"' >/dev/null || \
  fail "RKLLM health check failed after DAWN restart"

APPLIED=0
printf '%s\n' 'PASS: DAWN read-only maintenance inspection tool installed.'
printf 'Source and executable backup: %s\n' "$BACKUP"
printf 'Build log: %s\n' "$LOG"
printf '%s\n' 'Use it from a WebUI session with tools enabled: “Jarvis, run a maintenance inspection.”'
