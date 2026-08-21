#!/usr/bin/env bash
set -euo pipefail

readonly SOURCE='/srv/aibrain/test/builds/dawn-stage3-source'
readonly CAPTURES='/srv/aibrain/test/captures'
readonly STAMP="$(date -u +%Y%m%d-%H%M%S)"
readonly ARCHIVE="$CAPTURES/dawn-maintenance-tool-source-$STAMP.tar.gz"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -d "$SOURCE/src/tools" ]] || fail "Missing DAWN tool source: $SOURCE/src/tools"
[[ -d "$SOURCE/include/tools" ]] || fail "Missing DAWN tool headers: $SOURCE/include/tools"
mkdir -p "$CAPTURES"
tmp="$(mktemp -d "$CAPTURES/.dawn-maintenance-tool-source.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/source"
cp -a "$SOURCE/src/tools" "$tmp/source/src-tools"
cp -a "$SOURCE/include/tools" "$tmp/source/include-tools"
for path in CMakeLists.txt common/CMakeLists.txt; do
  [[ -f "$SOURCE/$path" ]] && install -D -m 0644 "$SOURCE/$path" "$tmp/source/$path"
done

find "$SOURCE/src" -type f -name 'tools_init.c' -printf '%P\n' >"$tmp/tools-init-paths.txt"
while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  install -D -m 0644 "$SOURCE/src/$relative" "$tmp/source/src/$relative"
done <"$tmp/tools-init-paths.txt"

{
  printf 'captured_at_utc=%s\n' "$STAMP"
  printf 'source=%s\n' "$SOURCE"
  git -C "$SOURCE" rev-parse HEAD 2>&1 || true
  git -C "$SOURCE" status --short 2>&1 || true
} >"$tmp/source-identity.txt"

find "$tmp/source" -type f -print0 | sort -z | xargs -0 sha256sum >"$tmp/source-SHA256SUMS.txt"
grep -RniE 'tool_registry|tools_init|tool_register|maintenance' "$tmp/source" >"$tmp/tool-references.txt" || true

tar -C "$tmp" -czf "$ARCHIVE" source source-identity.txt source-SHA256SUMS.txt tools-init-paths.txt tool-references.txt
printf 'PASS: DAWN maintenance-tool source capture created.\n'
printf 'Archive: %s\n' "$ARCHIVE"
printf 'Archive SHA-256: %s\n' "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
