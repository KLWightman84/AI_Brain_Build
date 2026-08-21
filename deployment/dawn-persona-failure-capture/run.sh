#!/usr/bin/env bash
set -euo pipefail
readonly SERVICE='dawn-stage3-webui-tts.service'
readonly CONFIG='/srv/aibrain/test/AI_Brain_Build/configs/dawn-stage3-webui-tts-alan.toml'
readonly CAPTURES='/srv/aibrain/test/captures'
tmp=$(mktemp -d "$CAPTURES/.dawn-persona-failure.XXXXXX")
stamp=$(date -u +%Y%m%d-%H%M%S)
archive="$CAPTURES/dawn-persona-failure-$stamp.tar.gz"
trap 'rm -rf -- "$tmp"' EXIT

redact() {
  sed -E \
    -e 's/gho_[A-Za-z0-9_]+/[GITHUB-TOKEN-REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]+/[GITHUB-TOKEN-REDACTED]/g' \
    -e 's/DAWN-[A-Za-z0-9-]+/[DAWN-TOKEN-REDACTED]/g' \
    -e 's/-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----/[PRIVATE-KEY-REDACTED]/g'
}

{
  printf 'captured_at_utc=%s\n' "$stamp"
  printf 'service=%s\n' "$SERVICE"
  systemctl --user show "$SERVICE" \
    -p LoadState -p ActiveState -p SubState -p Result \
    -p ExecMainCode -p ExecMainStatus -p MainPID
} | redact >"$tmp/service-state.txt"

systemctl --user status "$SERVICE" --no-pager -l 2>&1 | redact >"$tmp/service-status.txt" || true
journalctl --user -u "$SERVICE" -n 240 --no-pager -o short-iso 2>&1 | redact >"$tmp/service-log.txt" || true
sha256sum "$CONFIG" >"$tmp/config-sha256.txt"
grep -nE '^\[general\]|^\[persona\]|^ai_name|^description' "$CONFIG" | redact >"$tmp/config-persona-lines.txt" || true

if grep -RniE '(gho_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|DAWN-[A-Za-z0-9-]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' "$tmp"; then
  printf 'ERROR: sensitive-value redaction check failed; no archive created.\n' >&2
  exit 1
fi

tar -C "$tmp" -czf "$archive" service-state.txt service-status.txt service-log.txt config-sha256.txt config-persona-lines.txt
printf 'PASS: persona failure capture created.\nArchive: %s\nArchive SHA-256: %s\n' "$archive" "$(sha256sum "$archive" | awk '{print $1}')"
