#!/usr/bin/env bash
set -euo pipefail
readonly CONFIG='/srv/aibrain/test/AI_Brain_Build/configs/dawn-stage3-webui-tts-alan.toml'
readonly SERVICE='dawn-stage3-webui-tts.service'
readonly EXPECTED_SHA='fc193f0229480c722f6993da8f611cb1457a81e43f9494c21bd6316e12664ffb'
readonly BACKUPS='/srv/aibrain/test/backups'
readonly PERSONA_B64='WW91IGFyZSBKQVJWSVMsIGEgcmVmaW5lZCBhbmQgZGVwZW5kYWJsZSBwZXJzb25hbCBBSS4gU3BlYWsgd2l0aCBjb21wb3NlZCwgc3VidGx5IEJyaXRpc2ggcHJlY2lzaW9uOiBjb3VydGVvdXMsIGNvbmZpZGVudCwgbmV2ZXIgdGhlYXRyaWNhbC4gVXNlIGRyeSBodW1vciBhbmQgc2F5IHNpciBzcGFyaW5nbHkuIEFudGljaXBhdGUgdXNlZnVsIG5leHQgc3RlcHM7IHN0YXRlIHJpc2tzIGFuZCB0cmFkZW9mZnMgY2xlYXJseS4gTmV2ZXIgaW52ZW50IGFjdGlvbnMsIHJlc3VsdHMsIG1lbW9yaWVzLCBvciBjYXBhYmlsaXRpZXMuIFByb3RlY3QgcHJpdmFjeS4gRm9yIHRlY2huaWNhbCB3b3JrLCB2ZXJpZnkgZmlyc3QgYW5kIGtlZXAgY2hhbmdlcyBzY29wZWQsIHJldmVyc2libGUsIGFuZCB0ZXN0YWJsZS4='
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -f "$CONFIG" ]] || fail "Missing active config: $CONFIG"
[[ "$(sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_SHA" ]] || fail 'Active config identity changed since persona preflight'
grep -q '^\[persona\]$' "$CONFIG" && fail 'Config already contains a persona section'
grep -q '^\[general\]$' "$CONFIG" && fail 'Config already contains a general section'
persona="$(printf '%s' "$PERSONA_B64" | base64 -d)"
(( ${#persona} <= 500 )) || fail 'Persona exceeds DAWN 500-character limit'
[[ "$persona" != *'"'* && "$persona" != *$'\n'* ]] || fail 'Persona is not TOML single-line safe'
stamp=$(date -u +%Y%m%d-%H%M%S)
backup="$BACKUPS/dawn-stage3-webui-tts-alan-pre-jarvis-persona-$stamp.toml"
mkdir -p "$BACKUPS"
install -m 0600 "$CONFIG" "$backup"
restore(){ install -m 0644 "$backup" "$CONFIG"; systemctl --user restart "$SERVICE"; }
trap 'status=$?; if [[ $status -ne 0 ]]; then restore || true; fi; exit $status' EXIT
printf '\n[general]\nai_name = "Jarvis"\n\n[persona]\ndescription = "%s"\n' "$persona" >>"$CONFIG"
systemctl --user restart "$SERVICE"
for attempt in $(seq 1 60); do
  systemctl --user is-active --quiet "$SERVICE" && ss -ltnH | awk '$4=="127.0.0.1:3000"{ok=1} END{exit !ok}' && break
  sleep 1
done
systemctl --user is-active --quiet "$SERVICE" || fail 'DAWN service did not become active'
ss -ltnH | awk '$4=="127.0.0.1:3000"{ok=1} END{exit !ok}' || fail 'DAWN WebUI is not loopback-bound'
grep -Fx "ai_name = \"Jarvis\"" "$CONFIG" >/dev/null
grep -Fx "description = \"$persona\"" "$CONFIG" >/dev/null
printf 'PASS: JARVIS Persona v1 installed (%s characters).\n' "${#persona}"
printf 'Backup: %s\n' "$backup"
trap - EXIT
