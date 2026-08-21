#!/usr/bin/env bash
# Read-only discovery of the active DAWN persona integration surface.
set -euo pipefail

readonly SOURCE='/srv/aibrain/test/builds/dawn-stage3-source'
readonly CONFIG='/srv/aibrain/test/AI_Brain_Build/configs/dawn-stage3-webui-tts-alan.toml'
readonly CAPTURES='/srv/aibrain/test/captures'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in grep find tar sha256sum mktemp; do command -v "$command" >/dev/null || fail "Missing command: $command"; done
[[ -d "$SOURCE" ]] || fail "Missing DAWN source: $SOURCE"
[[ -f "$CONFIG" ]] || fail "Missing active DAWN config: $CONFIG"

stamp=$(date -u +%Y%m%d-%H%M%S)
tmp=$(mktemp -d "$CAPTURES/.dawn-persona-preflight.XXXXXX")
archive="$CAPTURES/dawn-persona-preflight-$stamp.tar.gz"
trap 'rm -rf -- "$tmp"' EXIT

grep -RniE 'persona|system_prompt|ai_name|assistant_name|identity' \
    "$SOURCE/src" "$SOURCE/include" >"$tmp/source-matches.txt" || true
grep -nEi '^\[|persona|system_prompt|ai_name|assistant_name|identity' \
    "$CONFIG" >"$tmp/config-matches.txt" || true
find "$SOURCE" -maxdepth 3 -type f \
    \( -name '*persona*' -o -name '*prompt*' \) -printf '%p\n' \
    >"$tmp/candidate-files.txt" 2>/dev/null || true
sha256sum "$CONFIG" >"$tmp/config-sha256.txt"

if grep -RniE '(gho_|github_pat_|DAWN-[A-Z0-9-]{12,}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' "$tmp"; then
    fail 'Sensitive-value scan failed; archive was not created'
fi

tar -C "$tmp" -czf "$archive" source-matches.txt config-matches.txt candidate-files.txt config-sha256.txt
printf 'PASS: DAWN persona preflight capture created.\n'
printf 'Archive: %s\n' "$archive"
printf 'Archive SHA-256: %s\n' "$(sha256sum "$archive" | awk '{print $1}')"
