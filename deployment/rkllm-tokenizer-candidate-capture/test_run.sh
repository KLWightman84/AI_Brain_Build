#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$(mktemp -d)"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

mkdir -p "$FIXTURE/input" "$FIXTURE/tokenizers" "$FIXTURE/captures"
printf 'not-a-real-model\n' >"$FIXTURE/input/model.rkllm"
printf '%s\n' '{"model":{"type":"BPE","vocab":{"x":0}},"added_tokens":[]}' >"$FIXTURE/input/tokenizer.json"

AIBRAIN_TOKENIZER_ROOT="$FIXTURE/tokenizers" \
AIBRAIN_CAPTURE_ROOT="$FIXTURE/captures" \
AIBRAIN_ACTIVE_MODEL="$FIXTURE/input/model.rkllm" \
AIBRAIN_TOKENIZER_URL="file://$FIXTURE/input/tokenizer.json" \
  bash "$SCRIPT_DIR/run.sh" >/dev/null

ARCHIVE="$(find "$FIXTURE/captures" -maxdepth 1 -name 'tokenizer-candidate-capture-*.tar.gz' -print -quit)"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]]
tar -xOzf "$ARCHIVE" manifest.json | grep -F '"tokenizer_model_type": "BPE"' >/dev/null
echo "PASS tokenizer-candidate capture test"
