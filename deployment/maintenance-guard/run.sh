#!/usr/bin/env bash
# Installs the reviewed, standalone maintenance guard.  This installer never
# alters DAWN/RKLLM/WebUI sources, configs, services, dependencies, or models.
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Usage: $0 <immutable-github-commit-sha>" >&2
    exit 2
fi

COMMIT="$1"
REPOSITORY="KLWightman84/AI_Brain_Build"
SOURCE_PATH="deployment/maintenance-guard/aibrain_maintenance.py"
SOURCE_SHA256="64fb783e64faaddacc0b4beb3a530083a057feaeb709e02e7086d231a6326e9c"
CONTRACT_PATH="deployment/maintenance-guard/AI_TOOL_CONTRACT.md"
CONTRACT_SHA256="7ba3591cfcc802e869ccaca67f8f8cf98682b2898588f0e7239e84840a14d1c6"
ROOT="${AIBRAIN_MAINTENANCE_ROOT:-/srv/aibrain/production/maintenance}"
RELEASE_DIR="$ROOT/releases/$SOURCE_SHA256"
TARGET="$RELEASE_DIR/aibrain-maintenance.py"
LAUNCHER="$ROOT/bin/aibrain-maintenance"
POLICY="$ROOT/policy.json"
CONTRACT="$ROOT/AI_TOOL_CONTRACT.md"
TEMP="$(mktemp)"
CONTRACT_TEMP="$(mktemp)"

cleanup() { rm -f "$TEMP" "$CONTRACT_TEMP"; }
trap cleanup EXIT

if [[ -e "$TARGET" ]]; then
    printf '%s  %s\n' "$SOURCE_SHA256" "$TARGET" | sha256sum -c -
else
    mkdir -p "$RELEASE_DIR" "$ROOT/bin" "$ROOT/evidence"
    curl --fail --location --silent --show-error \
        "https://raw.githubusercontent.com/$REPOSITORY/$COMMIT/$SOURCE_PATH" \
        -o "$TEMP"
    printf '%s  %s\n' "$SOURCE_SHA256" "$TEMP" | sha256sum -c -
    install -m 0750 "$TEMP" "$TARGET"
fi

if [[ -e "$LAUNCHER" && ! -L "$LAUNCHER" ]]; then
    echo "STOP: refusing to replace non-symlink launcher: $LAUNCHER" >&2
    exit 1
fi
ln -sfn "$TARGET" "$LAUNCHER"

if [[ -e "$CONTRACT" ]]; then
    printf '%s  %s\n' "$CONTRACT_SHA256" "$CONTRACT" | sha256sum -c -
else
    curl --fail --location --silent --show-error \
        "https://raw.githubusercontent.com/$REPOSITORY/$COMMIT/$CONTRACT_PATH" \
        -o "$CONTRACT_TEMP"
    printf '%s  %s\n' "$CONTRACT_SHA256" "$CONTRACT_TEMP" | sha256sum -c -
    install -m 0640 "$CONTRACT_TEMP" "$CONTRACT"
fi

if [[ ! -e "$POLICY" ]]; then
    "$LAUNCHER" --policy "$POLICY" install-policy
fi

echo "PASS: maintenance guard installed."
echo "Launcher: $LAUNCHER"
echo "Policy:   $POLICY"
echo "Contract: $CONTRACT"
echo "Next safe action: $LAUNCHER inspect --output $ROOT/evidence/initial-snapshot.json"
