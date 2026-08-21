#!/usr/bin/env bash
set -euo pipefail
readonly SERVICE='dawn-stage3-webui-tts.service'
readonly CONFIG='/srv/aibrain/test/AI_Brain_Build/configs/dawn-stage3-webui-tts-alan.toml'
readonly CAPTURES='/srv/aibrain/test/captures'
tmp=$(mktemp -d "$CAPTURES/.dawn-persona-failure.XXXXXX")
stamp=$(date -u +%Y%m%d-%H%M%S)
archive="$CAPTURES/dawn-persona-failure-$stamp.tar.gz"
trap 'rm -rf -- "$tmp"' EXIT
systemctl --user status "$SERVICE" --no-pager -l >"$tmp/service-status.txt" 2>&1 || true
journalctl --user -u "$SERVICE" -n 160 --no-pager -o short-iso >"$tmp/service-log.txt" 2>&1 || true
sha256sum "$CONFIG" >"$tmp/config-sha256.txt"
grep -nE '^\[general\]|^\[persona\]|^ai_name|^description' "$CONFIG" >"$tmp/config-persona-lines.txt" || true
if grep -RniE '(gho_|github_pat_|DAWN-[A-Z0-9-]{12,}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' "$tmp"; then exit 1; fi
tar -C "$tmp" -czf "$archive" service-status.txt service-log.txt config-sha256.txt config-persona-lines.txt
printf 'PASS: persona failure capture created.\nArchive: %s\nArchive SHA-256: %s\n' "$archive" "$(sha256sum "$archive" | awk '{print $1}')"
