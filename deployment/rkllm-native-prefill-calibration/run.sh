#!/usr/bin/env bash
# Temporarily expose native RKLLM prefill telemetry for tokenizer calibration.
# The adapter source is restored and re-verified before this script reports PASS.
set -euo pipefail

readonly APP='/srv/aibrain/production/apps/AI_Brain_Build'
readonly SERVICE="$APP/src/aibrain_rkllm/service.py"
readonly TESTS="$APP/tests/test_service.py"
readonly PYTHON='/srv/aibrain/production/runtime/rkllm-venv/bin/python3'
readonly HEALTH_URL='http://127.0.0.1:8081/healthz'
readonly SOURCE_SHA='6bb2338b4cf1118611053ac6a4c2c9d92ee2327ca02c0c3849d118dbb37278de'
readonly TESTS_SHA='db47fb02f432a9c68cba685c19ca717b1bf4e006603fb93f905f52c7f1b7d8ae'
readonly MODEL='/srv/aibrain/production/models/Qwen3.5-4B_w8a8_rk3588_ctx4096.rkllm'
readonly MODEL_SHA='f733cb8acc42fc8ce486c965f673da7918fbc1a1a6ae22c7991e389c34963056'
readonly TOKENIZER='/srv/aibrain/test/tokenizers/Qwen3.5-4B-c7429d5a8ed57f4a9cfdaf1af76a8943eba0ae97-tokenizer.json'
readonly TOKENIZER_SHA='5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42'
readonly TOKENIZER_VENV='/srv/aibrain/test/deps/rkllm-tokenizer-runtime/venv-tokenizers-0.21.4'
readonly WHEEL='/srv/aibrain/test/deps/rkllm-tokenizer-runtime/wheels/tokenizers-0.21.4-cp39-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl'
readonly WHEEL_SHA='39b376f5a1aee67b4d29032ee85511bbd1b99007ec735f7f35c8a2eb104eade5'
readonly BACKUP_ROOT='/srv/aibrain/test/backups'
readonly CAPTURE_ROOT='/srv/aibrain/test/captures'

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_file_sha() {
    local path="$1" expected="$2"
    [[ -f "$path" ]] || fail "Required file is missing: $path"
    local observed
    observed=$(sha256sum "$path" | awk '{print $1}')
    [[ "$observed" == "$expected" ]] || fail "SHA-256 mismatch for $path"
}

wait_for_health() {
    local attempt
    for attempt in $(seq 1 30); do
        if curl -fsS "$HEALTH_URL" >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

assert_loopback_listener() {
    ss -ltnH | awk '
        $4 == "127.0.0.1:8081" { loopback = 1 }
        $4 ~ /:8081$/ && $4 != "127.0.0.1:8081" { bad = 1 }
        END { exit (loopback && !bad) ? 0 : 1 }
    '
}

run_existing_tests() {
    "$PYTHON" -m py_compile "$SERVICE" "$TESTS"
    "$PYTHON" - "$TESTS" <<'PY'
import runpy
import sys

tests = runpy.run_path(sys.argv[1])
for name in sorted(key for key in tests if key.startswith("test_")):
    tests[name]()
    print(f"PASS {name}")
PY
}

run_prefill_trace_test() {
    "$PYTHON" - <<'PY'
from aibrain_rkllm.service import create_app

class Backend:
    model_id = "rkllm"

    def complete(self, prompt, max_new_tokens):
        return "READY"

    def complete_with_telemetry(self, prompt, max_new_tokens):
        return "READY", {"prefill_tokens": 42, "generated_tokens": 3}

    def stream(self, prompt, max_new_tokens):
        return iter(())

    def close(self):
        return None

client = create_app(Backend()).test_client()
response = client.post(
    "/v1/chat/completions",
    json={
        "model": "rkllm",
        "dawn_trace": "prefill",
        "messages": [{"role": "user", "content": "calibration check"}],
    },
)
assert response.status_code == 200, response.get_data(as_text=True)
assert response.get_json()["dawn_trace"] == {
    "prefill_tokens": 42,
    "generated_tokens": 3,
}
print("PASS temporary prefill trace route")
PY
}

[[ -x "$PYTHON" ]] || fail "Required interpreter is missing: $PYTHON"
command -v curl >/dev/null || fail 'curl is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'
command -v ss >/dev/null || fail 'ss is required'
command -v base64 >/dev/null || fail 'base64 is required'
command -v tar >/dev/null || fail 'tar is required'

require_file_sha "$SERVICE" "$SOURCE_SHA"
require_file_sha "$TESTS" "$TESTS_SHA"
require_file_sha "$MODEL" "$MODEL_SHA"
require_file_sha "$TOKENIZER" "$TOKENIZER_SHA"
require_file_sha "$WHEEL" "$WHEEL_SHA"
[[ -x "$TOKENIZER_VENV/bin/python" ]] || fail "Tokenizer test virtual environment is missing"
git -C "$APP" diff --check
mapfile -t tracked_changes < <(git -C "$APP" status --porcelain | awk '$1 != "??" {print $2}' | sort)
expected_changes=('src/aibrain_rkllm/service.py' 'tests/test_service.py')
[[ "${tracked_changes[*]}" == "${expected_changes[*]}" ]] || fail 'Tracked source changes are outside the captured adapter closure'
systemctl --user is-active --quiet aibrain-rkllm.service || fail 'RKLLM service is not active'
wait_for_health || fail 'RKLLM health endpoint is not ready'
assert_loopback_listener || fail 'RKLLM listener is not exclusively loopback-bound'

STAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/rkllm-prefill-calibration-$STAMP"
TMP_DIR=$(mktemp -d "$CAPTURE_ROOT/.rkllm-prefill-calibration.XXXXXX")
mkdir -p "$BACKUP_DIR"
PATCHED=0

restore_source() {
    [[ "$PATCHED" -eq 1 ]] || return 0
    install -m 0644 "$BACKUP_DIR/service.py" "$SERVICE"
    require_file_sha "$SERVICE" "$SOURCE_SHA"
    systemctl --user restart aibrain-rkllm.service
    wait_for_health || return 1
    assert_loopback_listener
    PATCHED=0
}

cleanup() {
    status=$?
    trap - EXIT
    if ! restore_source; then
        printf 'ERROR: failed to restore the verified RKLLM adapter source\n' >&2
        status=1
    fi
    rm -rf -- "$TMP_DIR"
    exit "$status"
}
trap cleanup EXIT

install -m 0600 "$SERVICE" "$BACKUP_DIR/service.py"
require_file_sha "$BACKUP_DIR/service.py" "$SOURCE_SHA"
PATCHED=1
base64 -d >"$SERVICE" <<'CALIBRATED_SERVICE'
IiIiTG9vcGJhY2stb25seSwgT3BlbkFJLXN0eWxlIEhUVFAgc2VydmljZSBvdmVyIHRoZSB2ZXJp
ZmllZCBSS0xMTSBydW50aW1lLiIiIgoKZnJvbSBfX2Z1dHVyZV9fIGltcG9ydCBhbm5vdGF0aW9u
cwoKaW1wb3J0IGN0eXBlcwppbXBvcnQganNvbgppbXBvcnQgcXVldWUKaW1wb3J0IHRocmVhZGlu
ZwppbXBvcnQgdGltZQppbXBvcnQgdXVpZApmcm9tIGNvbGxlY3Rpb25zLmFiYyBpbXBvcnQgR2Vu
ZXJhdG9yLCBJdGVyYWJsZQpmcm9tIGRhdGFjbGFzc2VzIGltcG9ydCBkYXRhY2xhc3MsIGZpZWxk
CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aApmcm9tIHR5cGluZyBpbXBvcnQgQW55LCBQcm90b2Nv
bAoKZnJvbSBmbGFzayBpbXBvcnQgRmxhc2ssIFJlc3BvbnNlLCBqc29uaWZ5LCByZXF1ZXN0LCBz
dHJlYW1fd2l0aF9jb250ZXh0Cgpmcm9tIC5pbmZlcmVuY2UgaW1wb3J0IFByb21wdFJlc3BvbnNl
Q29sbGVjdG9yLCBydW5fcHJvbXB0CmZyb20gLm1vZGVsIGltcG9ydCBJbml0aWFsaXplZFJLTExN
TW9kZWwsIGluaXRpYWxpemVfbW9kZWwKZnJvbSAubmF0aXZlIGltcG9ydCBsb2FkX3JrbGxtX2xp
YnJhcnkKZnJvbSAucHJvdG9jb2wgaW1wb3J0IFJLTExNUmVzdWx0LCBSS0xMTV9SVU5fRVJST1Is
IFJLTExNX1JVTl9GSU5JU0gsIFJLTExNX1JVTl9OT1JNQUwKClNFUlZJQ0VfTkFNRSA9ICJhaWJy
YWluLXJrbGxtIgpNT0RFTF9JRCA9ICJya2xsbSIKTUFYX0NPTlRFWFRfV09SRFMgPSAyNDAwCk1B
WF9ORVdfVE9LRU5TID0gNzY4Ck1PREVMX0NPTlRFWFRfVE9LRU5TID0gNDA5NgoKCmNsYXNzIENv
bXBsZXRpb25CYWNrZW5kKFByb3RvY29sKToKICAgIG1vZGVsX2lkOiBzdHIKCiAgICBkZWYgY29t
cGxldGUoc2VsZiwgcHJvbXB0OiBzdHIsIG1heF9uZXdfdG9rZW5zOiBpbnQpIC0+IHN0cjogLi4u
CgogICAgZGVmIGNvbXBsZXRlX3dpdGhfdGVsZW1ldHJ5KAogICAgICAgIHNlbGYsIHByb21wdDog
c3RyLCBtYXhfbmV3X3Rva2VuczogaW50CiAgICApIC0+IHR1cGxlW3N0ciwgZGljdFtzdHIsIGlu
dF1dOiAuLi4KCiAgICBkZWYgc3RyZWFtKHNlbGYsIHByb21wdDogc3RyLCBtYXhfbmV3X3Rva2Vu
czogaW50KSAtPiBJdGVyYWJsZVtzdHJdOiAuLi4KCiAgICBkZWYgY2xvc2Uoc2VsZikgLT4gTm9u
ZTogLi4uCgoKQGRhdGFjbGFzcwpjbGFzcyBRdWV1ZWRSZXN1bHRDb2xsZWN0b3IoUHJvbXB0UmVz
cG9uc2VDb2xsZWN0b3IpOgogICAgIiIiQ29sbGVjdCBjYWxsYmFjayB0ZXh0IGFuZCBleHBvc2Ug
ZWFjaCBmcmFnbWVudCB0byBvbmUgU1NFIGdlbmVyYXRvci4iIiIKCiAgICBjaHVua3M6IHF1ZXVl
LlF1ZXVlW3N0cl0gPSBmaWVsZChkZWZhdWx0X2ZhY3Rvcnk9cXVldWUuUXVldWUpCiAgICBwcmVm
aWxsX3Rva2VuczogaW50ID0gMAogICAgZ2VuZXJhdGVkX3Rva2VuczogaW50ID0gMAoKICAgIGRl
ZiByZXNldChzZWxmKSAtPiBOb25lOgogICAgICAgIHN1cGVyKCkucmVzZXQoKQogICAgICAgIHNl
bGYucHJlZmlsbF90b2tlbnMgPSAwCiAgICAgICAgc2VsZi5nZW5lcmF0ZWRfdG9rZW5zID0gMAog
ICAgICAgIHdoaWxlIFRydWU6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHNlbGYu
Y2h1bmtzLmdldF9ub3dhaXQoKQogICAgICAgICAgICBleGNlcHQgcXVldWUuRW1wdHk6CiAgICAg
ICAgICAgICAgICByZXR1cm4KCiAgICBkZWYgX19jYWxsX18oc2VsZiwgcmVzdWx0OiBjdHlwZXMu
UE9JTlRFUihSS0xMTVJlc3VsdCksIHN0YXRlOiBpbnQpIC0+IGludDoKICAgICAgICBpZiByZXN1
bHQ6CiAgICAgICAgICAgIHBlcmYgPSByZXN1bHQuY29udGVudHMucGVyZgogICAgICAgICAgICBp
ZiBwZXJmLnByZWZpbGxfdG9rZW5zID4gMDoKICAgICAgICAgICAgICAgIHNlbGYucHJlZmlsbF90
b2tlbnMgPSBpbnQocGVyZi5wcmVmaWxsX3Rva2VucykKICAgICAgICAgICAgaWYgcGVyZi5nZW5l
cmF0ZV90b2tlbnMgPiAwOgogICAgICAgICAgICAgICAgc2VsZi5nZW5lcmF0ZWRfdG9rZW5zID0g
aW50KHBlcmYuZ2VuZXJhdGVfdG9rZW5zKQogICAgICAgIGlmIHN0YXRlID09IFJLTExNX1JVTl9O
T1JNQUwgYW5kIHJlc3VsdCBhbmQgcmVzdWx0LmNvbnRlbnRzLnRleHQ6CiAgICAgICAgICAgIHBp
ZWNlID0gcmVzdWx0LmNvbnRlbnRzLnRleHQuZGVjb2RlKCJ1dGYtOCIsIGVycm9ycz0icmVwbGFj
ZSIpCiAgICAgICAgICAgIHNlbGYucGllY2VzLmFwcGVuZChwaWVjZSkKICAgICAgICAgICAgc2Vs
Zi5jaHVua3MucHV0KHBpZWNlKQogICAgICAgIGVsaWYgc3RhdGUgPT0gUktMTE1fUlVOX0ZJTklT
SDoKICAgICAgICAgICAgc2VsZi5maW5pc2hlZCA9IFRydWUKICAgICAgICBlbGlmIHN0YXRlID09
IFJLTExNX1JVTl9FUlJPUjoKICAgICAgICAgICAgc2VsZi5lcnJvcmVkID0gVHJ1ZQogICAgICAg
IHJldHVybiAwCgoKY2xhc3MgUktMTE1CYWNrZW5kOgogICAgIiIiQSBzaW5nbGUgc2VyaWFsaXpl
ZCBSS0xMTSBtb2RlbCBmb3Igc3luY2hyb25vdXMgYW5kIFNTRSByZXF1ZXN0cy4iIiIKCiAgICBt
b2RlbF9pZCA9IE1PREVMX0lECgogICAgZGVmIF9faW5pdF9fKHNlbGYsIGxpYnJhcnk6IEFueSwg
bW9kZWw6IEluaXRpYWxpemVkUktMTE1Nb2RlbCkgLT4gTm9uZToKICAgICAgICBzZWxmLl9saWJy
YXJ5ID0gbGlicmFyeQogICAgICAgIHNlbGYuX21vZGVsID0gbW9kZWwKICAgICAgICBzZWxmLl9j
b2xsZWN0b3IgPSBRdWV1ZWRSZXN1bHRDb2xsZWN0b3IoKQogICAgICAgIHNlbGYuX2xvY2sgPSB0
aHJlYWRpbmcuTG9jaygpCiAgICAgICAgc2VsZi5fY2xvc2VkID0gRmFsc2UKICAgICAgICBzZWxm
Ll9iaW5kX2NvbnRyb2xfY2FsbHMoKQoKICAgIEBjbGFzc21ldGhvZAogICAgZGVmIGxvYWQoY2xz
LCBsaWJyYXJ5X3BhdGg6IFBhdGgsIG1vZGVsX3BhdGg6IFBhdGgpIC0+ICJSS0xMTUJhY2tlbmQi
OgogICAgICAgIGxpYnJhcnkgPSBsb2FkX3JrbGxtX2xpYnJhcnkobGlicmFyeV9wYXRoKQogICAg
ICAgIGNvbGxlY3RvciA9IFF1ZXVlZFJlc3VsdENvbGxlY3RvcigpCiAgICAgICAgbW9kZWwgPSBp
bml0aWFsaXplX21vZGVsKGxpYnJhcnksIG1vZGVsX3BhdGgsIHJlc3VsdF9oYW5kbGVyPWNvbGxl
Y3RvcikKICAgICAgICBiYWNrZW5kID0gY2xzKGxpYnJhcnksIG1vZGVsKQogICAgICAgIGJhY2tl
bmQuX2NvbGxlY3RvciA9IGNvbGxlY3RvcgogICAgICAgIHJldHVybiBiYWNrZW5kCgogICAgZGVm
IF9iaW5kX2NvbnRyb2xfY2FsbHMoc2VsZikgLT4gTm9uZToKICAgICAgICBzZWxmLl9saWJyYXJ5
LnJrbGxtX2Fib3J0LmFyZ3R5cGVzID0gW2N0eXBlcy5jX3ZvaWRfcF0KICAgICAgICBzZWxmLl9s
aWJyYXJ5LnJrbGxtX2Fib3J0LnJlc3R5cGUgPSBjdHlwZXMuY19pbnQKICAgICAgICBzZWxmLl9s
aWJyYXJ5LnJrbGxtX2lzX3J1bm5pbmcuYXJndHlwZXMgPSBbY3R5cGVzLmNfdm9pZF9wXQogICAg
ICAgIHNlbGYuX2xpYnJhcnkucmtsbG1faXNfcnVubmluZy5yZXN0eXBlID0gY3R5cGVzLmNfaW50
CgogICAgZGVmIF9lbnN1cmVfb3BlbihzZWxmKSAtPiBOb25lOgogICAgICAgIGlmIHNlbGYuX2Ns
b3NlZDoKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCJSS0xMTSBzZXJ2aWNlIGJhY2tl
bmQgaXMgY2xvc2VkIikKCiAgICBkZWYgX2Fzc2VydF9maW5pc2hlZChzZWxmKSAtPiBOb25lOgog
ICAgICAgIGlmIHNlbGYuX2NvbGxlY3Rvci5lcnJvcmVkOgogICAgICAgICAgICByYWlzZSBSdW50
aW1lRXJyb3IoIlJLTExNIGNhbGxiYWNrIHJlcG9ydGVkIGFuIGVycm9yIikKICAgICAgICBpZiBu
b3Qgc2VsZi5fY29sbGVjdG9yLmZpbmlzaGVkOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJy
b3IoIlJLTExNIGNhbGxiYWNrIGRpZCBub3QgcmVwb3J0IGNvbXBsZXRpb24iKQoKICAgIGRlZiBf
Y29tcGxldGUoc2VsZiwgcHJvbXB0OiBzdHIsIG1heF9uZXdfdG9rZW5zOiBpbnQpIC0+IHR1cGxl
W3N0ciwgZGljdFtzdHIsIGludF1dOgogICAgICAgIHdpdGggc2VsZi5fbG9jazoKICAgICAgICAg
ICAgc2VsZi5fZW5zdXJlX29wZW4oKQogICAgICAgICAgICBzZWxmLl9jb2xsZWN0b3IucmVzZXQo
KQogICAgICAgICAgICBydW5fcHJvbXB0KHNlbGYuX2xpYnJhcnksIHNlbGYuX21vZGVsLCBwcm9t
cHQsIG1heF9uZXdfdG9rZW5zPW1heF9uZXdfdG9rZW5zKQogICAgICAgICAgICBzZWxmLl9hc3Nl
cnRfZmluaXNoZWQoKQogICAgICAgICAgICByZXNwb25zZSA9IHNlbGYuX2NvbGxlY3Rvci50ZXh0
LnN0cmlwKCkKICAgICAgICAgICAgaWYgbm90IHJlc3BvbnNlOgogICAgICAgICAgICAgICAgcmFp
c2UgUnVudGltZUVycm9yKCJSS0xMTSByZXR1cm5lZCBhbiBlbXB0eSByZXNwb25zZSIpCiAgICAg
ICAgICAgIHJldHVybiByZXNwb25zZSwgewogICAgICAgICAgICAgICAgInByZWZpbGxfdG9rZW5z
Ijogc2VsZi5fY29sbGVjdG9yLnByZWZpbGxfdG9rZW5zLAogICAgICAgICAgICAgICAgImdlbmVy
YXRlZF90b2tlbnMiOiBzZWxmLl9jb2xsZWN0b3IuZ2VuZXJhdGVkX3Rva2VucywKICAgICAgICAg
ICAgfQoKICAgIGRlZiBjb21wbGV0ZShzZWxmLCBwcm9tcHQ6IHN0ciwgbWF4X25ld190b2tlbnM6
IGludCkgLT4gc3RyOgogICAgICAgIHJldHVybiBzZWxmLl9jb21wbGV0ZShwcm9tcHQsIG1heF9u
ZXdfdG9rZW5zKVswXQoKICAgIGRlZiBjb21wbGV0ZV93aXRoX3RlbGVtZXRyeSgKICAgICAgICBz
ZWxmLCBwcm9tcHQ6IHN0ciwgbWF4X25ld190b2tlbnM6IGludAogICAgKSAtPiB0dXBsZVtzdHIs
IGRpY3Rbc3RyLCBpbnRdXToKICAgICAgICAiIiJSZXR1cm4gbmF0aXZlIGNhbGxiYWNrIGNvdW50
cyBmb3IgdGhlIHRlbXBvcmFyeSBjYWxpYnJhdGlvbiBlbmRwb2ludC4iIiIKICAgICAgICByZXR1
cm4gc2VsZi5fY29tcGxldGUocHJvbXB0LCBtYXhfbmV3X3Rva2VucykKCiAgICBkZWYgc3RyZWFt
KHNlbGYsIHByb21wdDogc3RyLCBtYXhfbmV3X3Rva2VuczogaW50KSAtPiBHZW5lcmF0b3Jbc3Ry
LCBOb25lLCBOb25lXToKICAgICAgICAiIiJZaWVsZCBjYWxsYmFjayBmcmFnbWVudHMgd2hpbGUg
b25lIHNlcmlhbGl6ZWQgbmF0aXZlIHJ1biBpcyBhY3RpdmUuIiIiCgogICAgICAgIGRlZiBnZW5l
cmF0ZSgpIC0+IEdlbmVyYXRvcltzdHIsIE5vbmUsIE5vbmVdOgogICAgICAgICAgICB3aXRoIHNl
bGYuX2xvY2s6CiAgICAgICAgICAgICAgICBzZWxmLl9lbnN1cmVfb3BlbigpCiAgICAgICAgICAg
ICAgICBzZWxmLl9jb2xsZWN0b3IucmVzZXQoKQogICAgICAgICAgICAgICAgZXJyb3I6IGxpc3Rb
QmFzZUV4Y2VwdGlvbl0gPSBbXQoKICAgICAgICAgICAgICAgIGRlZiB3b3JrZXIoKSAtPiBOb25l
OgogICAgICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgICAgICAgICAgcnVuX3By
b21wdCgKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYuX2xpYnJhcnksCiAgICAgICAg
ICAgICAgICAgICAgICAgICAgICBzZWxmLl9tb2RlbCwKICAgICAgICAgICAgICAgICAgICAgICAg
ICAgIHByb21wdCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIG1heF9uZXdfdG9rZW5zPW1h
eF9uZXdfdG9rZW5zLAogICAgICAgICAgICAgICAgICAgICAgICApCiAgICAgICAgICAgICAgICAg
ICAgZXhjZXB0IEJhc2VFeGNlcHRpb24gYXMgZXhjOgogICAgICAgICAgICAgICAgICAgICAgICBl
cnJvci5hcHBlbmQoZXhjKQoKICAgICAgICAgICAgICAgIHRocmVhZCA9IHRocmVhZGluZy5UaHJl
YWQodGFyZ2V0PXdvcmtlciwgbmFtZT0iYWlicmFpbi1ya2xsbS1pbmZlcmVuY2UiKQogICAgICAg
ICAgICAgICAgdGhyZWFkLnN0YXJ0KCkKICAgICAgICAgICAgICAgIGNvbXBsZXRlZCA9IEZhbHNl
CiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgd2hpbGUgdGhyZWFkLmlz
X2FsaXZlKCkgb3Igbm90IHNlbGYuX2NvbGxlY3Rvci5jaHVua3MuZW1wdHkoKToKICAgICAgICAg
ICAgICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgICAgICAgICAgeWllbGQgc2Vs
Zi5fY29sbGVjdG9yLmNodW5rcy5nZXQodGltZW91dD0wLjEpCiAgICAgICAgICAgICAgICAgICAg
ICAgIGV4Y2VwdCBxdWV1ZS5FbXB0eToKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNvbnRp
bnVlCiAgICAgICAgICAgICAgICAgICAgdGhyZWFkLmpvaW4oKQogICAgICAgICAgICAgICAgICAg
IGlmIGVycm9yOgogICAgICAgICAgICAgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoZiJS
S0xMTSBzdHJlYW1pbmcgcnVuIGZhaWxlZDoge2Vycm9yWzBdfSIpCiAgICAgICAgICAgICAgICAg
ICAgc2VsZi5fYXNzZXJ0X2ZpbmlzaGVkKCkKICAgICAgICAgICAgICAgICAgICBjb21wbGV0ZWQg
PSBUcnVlCiAgICAgICAgICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICAgICAgICAgIGlmIHRo
cmVhZC5pc19hbGl2ZSgpOgogICAgICAgICAgICAgICAgICAgICAgICBzZWxmLmFib3J0KCkKICAg
ICAgICAgICAgICAgICAgICAgICAgdGhyZWFkLmpvaW4odGltZW91dD01KQogICAgICAgICAgICAg
ICAgICAgICAgICBpZiB0aHJlYWQuaXNfYWxpdmUoKToKICAgICAgICAgICAgICAgICAgICAgICAg
ICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigiUktMTE0gd29ya2VyIGRpZCBub3Qgc3RvcCBhZnRlciBh
Ym9ydCIpCiAgICAgICAgICAgICAgICAgICAgaWYgbm90IGNvbXBsZXRlZCBhbmQgbm90IGVycm9y
IGFuZCBzZWxmLl9jb2xsZWN0b3IuZXJyb3JlZDoKICAgICAgICAgICAgICAgICAgICAgICAgcmFp
c2UgUnVudGltZUVycm9yKCJSS0xMTSBzdHJlYW1pbmcgY2FsbGJhY2sgcmVwb3J0ZWQgYW4gZXJy
b3IiKQoKICAgICAgICByZXR1cm4gZ2VuZXJhdGUoKQoKICAgIGRlZiBhYm9ydChzZWxmKSAtPiBO
b25lOgogICAgICAgICIiIkFib3J0IGFuIGFjdGl2ZSBuYXRpdmUgcmVxdWVzdCB3aXRob3V0IHJl
bGVhc2luZyB0aGUgbW9kZWwgaGFuZGxlLiIiIgogICAgICAgIGlmIHNlbGYuX2Nsb3NlZDoKICAg
ICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgc2VsZi5fbGlicmFyeS5ya2xsbV9pc19ydW5uaW5n
KHNlbGYuX21vZGVsLmhhbmRsZSkgPT0gMToKICAgICAgICAgICAgcmVzdWx0ID0gc2VsZi5fbGli
cmFyeS5ya2xsbV9hYm9ydChzZWxmLl9tb2RlbC5oYW5kbGUpCiAgICAgICAgICAgIGlmIHJlc3Vs
dCAhPSAwOgogICAgICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKGYicmtsbG1fYWJvcnQg
ZmFpbGVkIHdpdGggcmM9e3Jlc3VsdH0iKQoKICAgIGRlZiBjbG9zZShzZWxmKSAtPiBOb25lOgog
ICAgICAgICIiIkFib3J0IGlmIG5lZWRlZCBhbmQgcmVsZWFzZSB0aGUgc29sZSBuYXRpdmUgaGFu
ZGxlIGV4YWN0bHkgb25jZS4iIiIKICAgICAgICBpZiBzZWxmLl9jbG9zZWQ6CiAgICAgICAgICAg
IHJldHVybgogICAgICAgIHNlbGYuYWJvcnQoKQogICAgICAgIHdpdGggc2VsZi5fbG9jazoKICAg
ICAgICAgICAgaWYgc2VsZi5fY2xvc2VkOgogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAg
ICAgIHNlbGYuX21vZGVsLmNsb3NlKCkKICAgICAgICAgICAgc2VsZi5fY2xvc2VkID0gVHJ1ZQoK
CmRlZiBfdGV4dF9jb250ZW50KG1lc3NhZ2U6IGRpY3Rbc3RyLCBvYmplY3RdKSAtPiBzdHI6CiAg
ICBjb250ZW50ID0gbWVzc2FnZS5nZXQoImNvbnRlbnQiLCAiIikKICAgIGlmIGlzaW5zdGFuY2Uo
Y29udGVudCwgc3RyKToKICAgICAgICByZXR1cm4gY29udGVudAogICAgaWYgaXNpbnN0YW5jZShj
b250ZW50LCBsaXN0KToKICAgICAgICB0ZXh0X3BhcnRzOiBsaXN0W3N0cl0gPSBbXQogICAgICAg
IGZvciBwYXJ0IGluIGNvbnRlbnQ6CiAgICAgICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKHBhcnQs
IGRpY3QpIG9yIHBhcnQuZ2V0KCJ0eXBlIikgIT0gInRleHQiOgogICAgICAgICAgICAgICAgcmFp
c2UgVmFsdWVFcnJvcigibWVzc2FnZSBjb250ZW50IHBhcnRzIG11c3QgYmUgdGV4dCBwYXJ0cyIp
CiAgICAgICAgICAgIHRleHQgPSBwYXJ0LmdldCgidGV4dCIpCiAgICAgICAgICAgIGlmIG5vdCBp
c2luc3RhbmNlKHRleHQsIHN0cik6CiAgICAgICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCJt
ZXNzYWdlIHRleHQgcGFydHMgbXVzdCBjb250YWluIGEgc3RyaW5nIikKICAgICAgICAgICAgdGV4
dF9wYXJ0cy5hcHBlbmQodGV4dCkKICAgICAgICByZXR1cm4gIiAiLmpvaW4odGV4dF9wYXJ0cykK
ICAgIHJhaXNlIFZhbHVlRXJyb3IoIm1lc3NhZ2UgY29udGVudCBtdXN0IGJlIGEgc3RyaW5nIG9y
IHRleHQtcGFydCBhcnJheSIpCgoKZGVmIF90YWlsX3dvcmRzKHRleHQ6IHN0ciwgbWF4aW11bTog
aW50KSAtPiBzdHI6CiAgICBpZiBtYXhpbXVtIDw9IDA6CiAgICAgICAgcmV0dXJuICIiCiAgICB3
b3JkcyA9IHRleHQuc3BsaXQoKQogICAgcmV0dXJuICIgIi5qb2luKHdvcmRzWy1tYXhpbXVtOl0p
CgoKZGVmIGJ1aWxkX3JlcXVlc3RfcHJvbXB0KG1lc3NhZ2VzOiBvYmplY3QsIGRhd25fY29udGV4
dDogb2JqZWN0ID0gIiIpIC0+IHN0cjoKICAgICIiIkJ1aWxkIG9uZSBzdGF0ZWxlc3MgcHJvbXB0
IHdoaWxlIHByZXNlcnZpbmcgREFXTidzIG1lc3NhZ2Ugc2VtYW50aWNzLiIiIgogICAgaWYgbm90
IGlzaW5zdGFuY2UobWVzc2FnZXMsIGxpc3QpIG9yIG5vdCBtZXNzYWdlczoKICAgICAgICByYWlz
ZSBWYWx1ZUVycm9yKCInbWVzc2FnZXMnIG11c3QgYmUgYSBub24tZW1wdHkgYXJyYXkiKQogICAg
aWYgbm90IGlzaW5zdGFuY2UoZGF3bl9jb250ZXh0LCBzdHIpOgogICAgICAgIHJhaXNlIFZhbHVl
RXJyb3IoIidkYXduX2NvbnRleHQnIG11c3QgYmUgYSBzdHJpbmciKQoKICAgIG5vcm1hbGl6ZWQ6
IGxpc3RbdHVwbGVbc3RyLCBzdHJdXSA9IFtdCiAgICBjdXJyZW50X2luZGV4ID0gLTEKICAgIGZv
ciBtZXNzYWdlIGluIG1lc3NhZ2VzOgogICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKG1lc3NhZ2Us
IGRpY3QpOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCJlYWNoIG1lc3NhZ2UgbXVzdCBi
ZSBhbiBvYmplY3QiKQogICAgICAgIHJvbGUgPSBtZXNzYWdlLmdldCgicm9sZSIpCiAgICAgICAg
aWYgbm90IGlzaW5zdGFuY2Uocm9sZSwgc3RyKToKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJv
cigibWVzc2FnZSByb2xlIG11c3QgYmUgYSBzdHJpbmciKQogICAgICAgIGlmIHJvbGUgbm90IGlu
ICgic3lzdGVtIiwgInVzZXIiLCAiYXNzaXN0YW50IiwgInRvb2wiKToKICAgICAgICAgICAgY29u
dGludWUKCiAgICAgICAgY29udGVudCA9IF90ZXh0X2NvbnRlbnQobWVzc2FnZSkKICAgICAgICBu
b3JtYWxpemVkLmFwcGVuZCgocm9sZSwgY29udGVudCkpCiAgICAgICAgaWYgcm9sZSBpbiAoInVz
ZXIiLCAidG9vbCIpIGFuZCBjb250ZW50LnN0cmlwKCk6CiAgICAgICAgICAgIGN1cnJlbnRfaW5k
ZXggPSBsZW4obm9ybWFsaXplZCkgLSAxCgogICAgaWYgY3VycmVudF9pbmRleCA8IDA6CiAgICAg
ICAgcmFpc2UgVmFsdWVFcnJvcigibWVzc2FnZXMgbXVzdCBjb250YWluIGEgbm9uLWVtcHR5IHVz
ZXIgb3IgdG9vbCBtZXNzYWdlIikKCiAgICBzeXN0ZW1fcGFydHM6IGxpc3Rbc3RyXSA9IFtdCiAg
ICBoaXN0b3J5X3BhcnRzOiBsaXN0W3N0cl0gPSBbXQogICAgaWYgZGF3bl9jb250ZXh0LnN0cmlw
KCk6CiAgICAgICAgaGlzdG9yeV9wYXJ0cy5hcHBlbmQoZiJBZGRpdGlvbmFsIHJlZmVyZW5jZSBj
b250ZXh0OiB7ZGF3bl9jb250ZXh0fSIpCgogICAgZm9yIHJvbGUsIGNvbnRlbnQgaW4gbm9ybWFs
aXplZFs6Y3VycmVudF9pbmRleF06CiAgICAgICAgaWYgbm90IGNvbnRlbnQuc3RyaXAoKToKICAg
ICAgICAgICAgY29udGludWUKICAgICAgICBpZiByb2xlID09ICJzeXN0ZW0iOgogICAgICAgICAg
ICBzeXN0ZW1fcGFydHMuYXBwZW5kKGNvbnRlbnQpCiAgICAgICAgZWxzZToKICAgICAgICAgICAg
aGlzdG9yeV9wYXJ0cy5hcHBlbmQoZiJ7cm9sZS5jYXBpdGFsaXplKCl9OiB7Y29udGVudH0iKQoK
ICAgIGN1cnJlbnRfcm9sZSwgY3VycmVudF90ZXh0ID0gbm9ybWFsaXplZFtjdXJyZW50X2luZGV4
XQogICAgc3lzdGVtX3RleHQgPSAiXG5cbiIuam9pbihzeXN0ZW1fcGFydHMpCiAgICByZWZlcmVu
Y2VfdGV4dCA9ICJcblxuIi5qb2luKGhpc3RvcnlfcGFydHMpCiAgICByZXNlcnZlZF93b3JkcyA9
IGxlbihzeXN0ZW1fdGV4dC5zcGxpdCgpKSArIGxlbihjdXJyZW50X3RleHQuc3BsaXQoKSkKICAg
IGJvdW5kZWRfaGlzdG9yeSA9IF90YWlsX3dvcmRzKHJlZmVyZW5jZV90ZXh0LCBNQVhfQ09OVEVY
VF9XT1JEUyAtIHJlc2VydmVkX3dvcmRzKQoKICAgIHBhcnRzOiBsaXN0W3N0cl0gPSBbXQogICAg
aWYgc3lzdGVtX3RleHQ6CiAgICAgICAgcGFydHMuYXBwZW5kKGYiU1lTVEVNIElOU1RSVUNUSU9O
UzpcbntzeXN0ZW1fdGV4dH0iKQogICAgaWYgYm91bmRlZF9oaXN0b3J5OgogICAgICAgIHBhcnRz
LmFwcGVuZChmIlBSSU9SIENPTlZFUlNBVElPTjpcbntib3VuZGVkX2hpc3Rvcnl9IikKCiAgICBj
dXJyZW50X2xhYmVsID0gIkNVUlJFTlQgVVNFUiBSRVFVRVNUIiBpZiBjdXJyZW50X3JvbGUgPT0g
InVzZXIiIGVsc2UgIkNVUlJFTlQgVE9PTCBSRVNVTFQiCiAgICBwYXJ0cy5hcHBlbmQoZiJ7Y3Vy
cmVudF9sYWJlbH06XG57Y3VycmVudF90ZXh0fSIpCiAgICByZXR1cm4gIlxuXG4iLmpvaW4ocGFy
dHMpCgoKZGVmIF9wYXJzZV9tYXhfdG9rZW5zKHZhbHVlOiBvYmplY3QpIC0+IGludDoKICAgIGlm
IHZhbHVlIGlzIE5vbmU6CiAgICAgICAgcmV0dXJuIDEyOAogICAgaWYgaXNpbnN0YW5jZSh2YWx1
ZSwgYm9vbCkgb3Igbm90IGlzaW5zdGFuY2UodmFsdWUsIGludCk6CiAgICAgICAgcmFpc2UgVmFs
dWVFcnJvcigiJ21heF90b2tlbnMnIG11c3QgYmUgYW4gaW50ZWdlciIpCiAgICBpZiBub3QgMSA8
PSB2YWx1ZSA8PSBNQVhfTkVXX1RPS0VOUzoKICAgICAgICByYWlzZSBWYWx1ZUVycm9yKGYiJ21h
eF90b2tlbnMnIG11c3QgYmUgYmV0d2VlbiAxIGFuZCB7TUFYX05FV19UT0tFTlN9IikKICAgIHJl
dHVybiB2YWx1ZQoKCmRlZiBfY29tcGxldGlvbl9yZXNwb25zZSgKICAgIG1vZGVsX2lkOiBzdHIs
IGNvbnRlbnQ6IHN0ciwgdGVsZW1ldHJ5OiBkaWN0W3N0ciwgaW50XSB8IE5vbmUgPSBOb25lCikg
LT4gZGljdFtzdHIsIG9iamVjdF06CiAgICBub3cgPSBpbnQodGltZS50aW1lKCkpCiAgICByZXNw
b25zZTogZGljdFtzdHIsIG9iamVjdF0gPSB7CiAgICAgICAgImlkIjogZiJjaGF0Y21wbC17dXVp
ZC51dWlkNCgpLmhleH0iLAogICAgICAgICJvYmplY3QiOiAiY2hhdC5jb21wbGV0aW9uIiwKICAg
ICAgICAiY3JlYXRlZCI6IG5vdywKICAgICAgICAibW9kZWwiOiBtb2RlbF9pZCwKICAgICAgICAi
Y2hvaWNlcyI6IFsKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgImluZGV4IjogMCwKICAg
ICAgICAgICAgICAgICJtZXNzYWdlIjogeyJyb2xlIjogImFzc2lzdGFudCIsICJjb250ZW50Ijog
Y29udGVudH0sCiAgICAgICAgICAgICAgICAiZmluaXNoX3JlYXNvbiI6ICJzdG9wIiwKICAgICAg
ICAgICAgfQogICAgICAgIF0sCiAgICB9CiAgICBpZiB0ZWxlbWV0cnkgaXMgbm90IE5vbmU6CiAg
ICAgICAgcmVzcG9uc2VbImRhd25fdHJhY2UiXSA9IHRlbGVtZXRyeQogICAgcmV0dXJuIHJlc3Bv
bnNlCgoKZGVmIF9zc2UocGF5bG9hZDogb2JqZWN0KSAtPiBzdHI6CiAgICByZXR1cm4gZiJkYXRh
OiB7anNvbi5kdW1wcyhwYXlsb2FkLCBzZXBhcmF0b3JzPSgnLCcsICc6JykpfVxuXG4iCgoKZGVm
IGNyZWF0ZV9hcHAoYmFja2VuZDogQ29tcGxldGlvbkJhY2tlbmQpIC0+IEZsYXNrOgogICAgIiIi
Q3JlYXRlIHRoZSBzZXJ2aWNlIGFwcCB3aXRob3V0IGJpbmRpbmcgYSBuZXR3b3JrIHNvY2tldC4i
IiIKCiAgICBhcHAgPSBGbGFzayhfX25hbWVfXykKCiAgICBAYXBwLmdldCgiL2hlYWx0aHoiKQog
ICAgZGVmIGhlYWx0aHooKSAtPiBSZXNwb25zZToKICAgICAgICByZXR1cm4ganNvbmlmeSgKICAg
ICAgICAgICAgeyJzdGF0dXMiOiAib2siLCAic2VydmljZSI6IFNFUlZJQ0VfTkFNRSwgIm1vZGVs
IjogYmFja2VuZC5tb2RlbF9pZH0KICAgICAgICApCgogICAgQGFwcC5nZXQoIi92MS9kYXduL3N0
YXR1cyIpCiAgICBkZWYgZGF3bl9zdGF0dXMoKSAtPiBSZXNwb25zZToKICAgICAgICAiIiJFeHBv
c2UgdGhlIFJLTExNIGFydGlmYWN0IGNvbnRleHQgbGltaXQgREFXTiBuZWVkcyBmb3Igc2FmZSBi
dWRnZXRpbmcuIiIiCiAgICAgICAgcmV0dXJuIGpzb25pZnkoCiAgICAgICAgICAgIHsKICAgICAg
ICAgICAgICAgICJiYWNrZW5kIjogInJrbGxtIiwKICAgICAgICAgICAgICAgICJtb2RlbCI6IGJh
Y2tlbmQubW9kZWxfaWQsCiAgICAgICAgICAgICAgICAibWF4X2NvbnRleHRfbGVuZ3RoIjogTU9E
RUxfQ09OVEVYVF9UT0tFTlMsCiAgICAgICAgICAgIH0KICAgICAgICApCgogICAgQGFwcC5nZXQo
Ii92MS9tb2RlbHMiKQogICAgZGVmIG1vZGVscygpIC0+IFJlc3BvbnNlOgogICAgICAgIHJldHVy
biBqc29uaWZ5KAogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAib2JqZWN0IjogImxpc3Qi
LAogICAgICAgICAgICAgICAgImRhdGEiOiBbCiAgICAgICAgICAgICAgICAgICAgewogICAgICAg
ICAgICAgICAgICAgICAgICAiaWQiOiBiYWNrZW5kLm1vZGVsX2lkLAogICAgICAgICAgICAgICAg
ICAgICAgICAib2JqZWN0IjogIm1vZGVsIiwKICAgICAgICAgICAgICAgICAgICAgICAgIm93bmVk
X2J5IjogInJrbGxtIiwKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBdLAog
ICAgICAgICAgICB9CiAgICAgICAgKQoKICAgIEBhcHAucG9zdCgiL3YxL2NoYXQvY29tcGxldGlv
bnMiKQogICAgZGVmIGNoYXRfY29tcGxldGlvbnMoKSAtPiBSZXNwb25zZToKICAgICAgICBkYXRh
ID0gcmVxdWVzdC5nZXRfanNvbihzaWxlbnQ9VHJ1ZSkKICAgICAgICBpZiBub3QgaXNpbnN0YW5j
ZShkYXRhLCBkaWN0KToKICAgICAgICAgICAgcmV0dXJuIGpzb25pZnkoeyJlcnJvciI6IHsibWVz
c2FnZSI6ICJyZXF1ZXN0IGJvZHkgbXVzdCBiZSBhIEpTT04gb2JqZWN0In19KSwgNDAwCiAgICAg
ICAgdHJ5OgogICAgICAgICAgICBwcm9tcHQgPSBidWlsZF9yZXF1ZXN0X3Byb21wdCgKICAgICAg
ICAgICAgICAgIGRhdGEuZ2V0KCJtZXNzYWdlcyIpLCBkYXRhLmdldCgiZGF3bl9jb250ZXh0Iiwg
IiIpCiAgICAgICAgICAgICkKICAgICAgICAgICAgbWF4X25ld190b2tlbnMgPSBfcGFyc2VfbWF4
X3Rva2VucyhkYXRhLmdldCgibWF4X3Rva2VucyIpKQogICAgICAgICAgICBzdHJlYW0gPSBkYXRh
LmdldCgic3RyZWFtIiwgRmFsc2UpCiAgICAgICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKHN0cmVh
bSwgYm9vbCk6CiAgICAgICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCInc3RyZWFtJyBtdXN0
IGJlIGEgYm9vbGVhbiIpCiAgICAgICAgICAgIHRyYWNlID0gZGF0YS5nZXQoImRhd25fdHJhY2Ui
KQogICAgICAgICAgICBpZiB0cmFjZSBpcyBub3QgTm9uZSBhbmQgdHJhY2UgIT0gInByZWZpbGwi
OgogICAgICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigiJ2Rhd25fdHJhY2UnIG11c3QgYmUg
J3ByZWZpbGwnIHdoZW4gcHJvdmlkZWQiKQogICAgICAgIGV4Y2VwdCBWYWx1ZUVycm9yIGFzIGVy
cm9yOgogICAgICAgICAgICByZXR1cm4ganNvbmlmeSh7ImVycm9yIjogeyJtZXNzYWdlIjogc3Ry
KGVycm9yKX19KSwgNDAwCgogICAgICAgIG1vZGVsX2lkID0gZGF0YS5nZXQoIm1vZGVsIiwgYmFj
a2VuZC5tb2RlbF9pZCkKICAgICAgICBpZiBtb2RlbF9pZCAhPSBiYWNrZW5kLm1vZGVsX2lkOgog
ICAgICAgICAgICByZXR1cm4ganNvbmlmeSh7ImVycm9yIjogeyJtZXNzYWdlIjogZiJ1bmtub3du
IG1vZGVsOiB7bW9kZWxfaWR9In19KSwgNDA0CgogICAgICAgIGlmIG5vdCBzdHJlYW06CiAgICAg
ICAgICAgIHRyeToKICAgICAgICAgICAgICAgIGlmIHRyYWNlID09ICJwcmVmaWxsIjoKICAgICAg
ICAgICAgICAgICAgICBjb250ZW50LCB0ZWxlbWV0cnkgPSBiYWNrZW5kLmNvbXBsZXRlX3dpdGhf
dGVsZW1ldHJ5KAogICAgICAgICAgICAgICAgICAgICAgICBwcm9tcHQsIG1heF9uZXdfdG9rZW5z
CiAgICAgICAgICAgICAgICAgICAgKQogICAgICAgICAgICAgICAgICAgIHJldHVybiBqc29uaWZ5
KAogICAgICAgICAgICAgICAgICAgICAgICBfY29tcGxldGlvbl9yZXNwb25zZShiYWNrZW5kLm1v
ZGVsX2lkLCBjb250ZW50LCB0ZWxlbWV0cnkpCiAgICAgICAgICAgICAgICAgICAgKQogICAgICAg
ICAgICAgICAgcmV0dXJuIGpzb25pZnkoCiAgICAgICAgICAgICAgICAgICAgX2NvbXBsZXRpb25f
cmVzcG9uc2UoCiAgICAgICAgICAgICAgICAgICAgICAgIGJhY2tlbmQubW9kZWxfaWQsCiAgICAg
ICAgICAgICAgICAgICAgICAgIGJhY2tlbmQuY29tcGxldGUocHJvbXB0LCBtYXhfbmV3X3Rva2Vu
cyksCiAgICAgICAgICAgICAgICAgICAgKQogICAgICAgICAgICAgICAgKQogICAgICAgICAgICBl
eGNlcHQgUnVudGltZUVycm9yIGFzIGVycm9yOgogICAgICAgICAgICAgICAgcmV0dXJuIGpzb25p
ZnkoeyJlcnJvciI6IHsibWVzc2FnZSI6IHN0cihlcnJvcil9fSksIDUwMwoKICAgICAgICBzdHJl
YW1faWQgPSBmImNoYXRjbXBsLXt1dWlkLnV1aWQ0KCkuaGV4fSIKCiAgICAgICAgZGVmIGV2ZW50
cygpIC0+IEdlbmVyYXRvcltzdHIsIE5vbmUsIE5vbmVdOgogICAgICAgICAgICB5aWVsZCBfc3Nl
KAogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgICJpZCI6IHN0cmVhbV9pZCwK
ICAgICAgICAgICAgICAgICAgICAib2JqZWN0IjogImNoYXQuY29tcGxldGlvbi5jaHVuayIsCiAg
ICAgICAgICAgICAgICAgICAgIm1vZGVsIjogYmFja2VuZC5tb2RlbF9pZCwKICAgICAgICAgICAg
ICAgICAgICAiY2hvaWNlcyI6IFt7ImluZGV4IjogMCwgImRlbHRhIjogeyJyb2xlIjogImFzc2lz
dGFudCJ9LCAiZmluaXNoX3JlYXNvbiI6IE5vbmV9XSwKICAgICAgICAgICAgICAgIH0KICAgICAg
ICAgICAgKQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBmb3IgY2h1bmsgaW4gYmFj
a2VuZC5zdHJlYW0ocHJvbXB0LCBtYXhfbmV3X3Rva2Vucyk6CiAgICAgICAgICAgICAgICAgICAg
eWllbGQgX3NzZSgKICAgICAgICAgICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAg
ICAgICAgICAgImlkIjogc3RyZWFtX2lkLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIm9i
amVjdCI6ICJjaGF0LmNvbXBsZXRpb24uY2h1bmsiLAogICAgICAgICAgICAgICAgICAgICAgICAg
ICAgIm1vZGVsIjogYmFja2VuZC5tb2RlbF9pZCwKICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICJjaG9pY2VzIjogW3siaW5kZXgiOiAwLCAiZGVsdGEiOiB7ImNvbnRlbnQiOiBjaHVua30sICJm
aW5pc2hfcmVhc29uIjogTm9uZX1dLAogICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAg
ICAgICAgICAgICAgKQogICAgICAgICAgICAgICAgeWllbGQgX3NzZSgKICAgICAgICAgICAgICAg
ICAgICB7CiAgICAgICAgICAgICAgICAgICAgICAgICJpZCI6IHN0cmVhbV9pZCwKICAgICAgICAg
ICAgICAgICAgICAgICAgIm9iamVjdCI6ICJjaGF0LmNvbXBsZXRpb24uY2h1bmsiLAogICAgICAg
ICAgICAgICAgICAgICAgICAibW9kZWwiOiBiYWNrZW5kLm1vZGVsX2lkLAogICAgICAgICAgICAg
ICAgICAgICAgICAiY2hvaWNlcyI6IFt7ImluZGV4IjogMCwgImRlbHRhIjoge30sICJmaW5pc2hf
cmVhc29uIjogInN0b3AifV0sCiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAg
KQogICAgICAgICAgICAgICAgeWllbGQgImRhdGE6IFtET05FXVxuXG4iCiAgICAgICAgICAgIGV4
Y2VwdCBSdW50aW1lRXJyb3IgYXMgZXJyb3I6CiAgICAgICAgICAgICAgICB5aWVsZCBfc3NlKHsi
ZXJyb3IiOiB7Im1lc3NhZ2UiOiBzdHIoZXJyb3IpfX0pCgogICAgICAgIHJldHVybiBSZXNwb25z
ZSgKICAgICAgICAgICAgc3RyZWFtX3dpdGhfY29udGV4dChldmVudHMoKSksCiAgICAgICAgICAg
IGNvbnRlbnRfdHlwZT0idGV4dC9ldmVudC1zdHJlYW0iLAogICAgICAgICAgICBoZWFkZXJzPXsi
Q2FjaGUtQ29udHJvbCI6ICJuby1jYWNoZSIsICJYLUFjY2VsLUJ1ZmZlcmluZyI6ICJubyJ9LAog
ICAgICAgICkKCiAgICByZXR1cm4gYXBwCg==
CALIBRATED_SERVICE
CALIBRATION_SHA=$(sha256sum "$SERVICE" | awk '{print $1}')
"$PYTHON" -m py_compile "$SERVICE"
run_existing_tests
run_prefill_trace_test

systemctl --user restart aibrain-rkllm.service
wait_for_health || fail 'Temporary telemetry service did not become healthy'
assert_loopback_listener || fail 'Temporary telemetry service listener changed'

PYTHONPATH="$TOKENIZER_VENV/lib/python3.12/site-packages:$APP/src" "$PYTHON" - \
    "$TOKENIZER" "$TMP_DIR/native-prefill-results.json" <<'PY'
import json
import pathlib
import sys
import time
import urllib.request

from aibrain_rkllm.service import build_request_prompt
from tokenizers import Tokenizer

tokenizer_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
tokenizer = Tokenizer.from_file(str(tokenizer_path))

cases = [
    {
        "name": "minimal_user",
        "messages": [{"role": "user", "content": "Reply exactly READY."}],
        "dawn_context": "",
    },
    {
        "name": "system_instruction",
        "messages": [
            {"role": "system", "content": "Respond precisely and concisely. " * 180},
            {"role": "user", "content": "Reply exactly READY."},
        ],
        "dawn_context": "",
    },
    {
        "name": "conversation_history",
        "messages": [
            {"role": "system", "content": "You are a careful local assistant."},
            {"role": "user", "content": "Summarize the forge inspection."},
            {"role": "assistant", "content": "The forge inspection found no safety defects. " * 45},
            {"role": "user", "content": "Reply exactly READY."},
        ],
        "dawn_context": "",
    },
    {
        "name": "reference_context",
        "messages": [{"role": "user", "content": "Reply exactly READY."}],
        "dawn_context": "reference " * 1200,
    },
    {
        "name": "unicode",
        "messages": [
            {"role": "system", "content": "Jarvis should preserve multilingual text."},
            {"role": "user", "content": "你好，Jarvis — reply exactly READY. 👋"},
        ],
        "dawn_context": "",
    },
    {
        "name": "dense_text",
        "messages": [
            {"role": "user", "content": ("aGVsbG8vKysvPT09" * 150) + " Reply exactly READY."}
        ],
        "dawn_context": "",
    },
]

results = []
for case in cases:
    prompt = build_request_prompt(case["messages"], case["dawn_context"])
    candidate_tokens = len(tokenizer.encode(prompt, add_special_tokens=False).ids)
    request_body = {
        "model": "rkllm",
        "max_tokens": 8,
        "dawn_trace": "prefill",
        "messages": case["messages"],
        "dawn_context": case["dawn_context"],
    }
    request = urllib.request.Request(
        "http://127.0.0.1:8081/v1/chat/completions",
        data=json.dumps(request_body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        body = json.loads(response.read().decode("utf-8"))
    trace = body.get("dawn_trace")
    if not isinstance(trace, dict):
        raise SystemExit(f"{case['name']}: native prefill trace was missing")
    native_tokens = trace.get("prefill_tokens")
    generated_tokens = trace.get("generated_tokens")
    if not isinstance(native_tokens, int) or native_tokens <= 0:
        raise SystemExit(f"{case['name']}: invalid native prefill count")
    if native_tokens < candidate_tokens:
        raise SystemExit(
            f"{case['name']}: native prefill {native_tokens} < candidate count {candidate_tokens}"
        )
    results.append(
        {
            "name": case["name"],
            "candidate_tokens": candidate_tokens,
            "native_prefill_tokens": native_tokens,
            "native_generated_tokens": generated_tokens,
            "envelope_tokens": native_tokens - candidate_tokens,
        }
    )

output_path.write_text(
    json.dumps(
        {
            "schema": 1,
            "kind": "rkllm_native_prefill_calibration",
            "captured_at_utc": time.strftime("%Y%m%d-%H%M%S", time.gmtime()),
            "candidate_tokenizer_counting": "tokenizer.json with add_special_tokens=false",
            "native_measurement": "RKLLM callback perf.prefill_tokens",
            "cases": results,
            "maximum_envelope_tokens": max(row["envelope_tokens"] for row in results),
            "recommended_reserve_tokens": max(row["envelope_tokens"] for row in results) + 32,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
PY

restore_source
run_existing_tests
require_file_sha "$SERVICE" "$SOURCE_SHA"

python3 - "$TMP_DIR/manifest.json" "$TMP_DIR/native-prefill-results.json" "$SERVICE" "$TESTS" "$MODEL" "$TOKENIZER" "$WHEEL" "$CALIBRATION_SHA" <<'PY'
import hashlib
import json
import pathlib
import sys
import time

manifest_path, results_path, service_path, tests_path, model_path, tokenizer_path, wheel_path = map(pathlib.Path, sys.argv[1:8])
calibration_sha = sys.argv[8]

def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

manifest = {
    "schema": 1,
    "kind": "rkllm_native_prefill_calibration_capture",
    "captured_at_utc": time.strftime("%Y%m%d-%H%M%S", time.gmtime()),
    "certification": "measurement candidate only; no trimming behavior was retained",
    "adapter_source_before_sha256": sha256(service_path),
    "adapter_source_temporary_telemetry_sha256": calibration_sha,
    "adapter_source_restored_sha256": sha256(service_path),
    "adapter_tests_sha256": sha256(tests_path),
    "active_rkllm_model_sha256": sha256(model_path),
    "tokenizer_sha256": sha256(tokenizer_path),
    "tokenizer_wheel_sha256": sha256(wheel_path),
    "results_sha256": sha256(results_path),
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

ARCHIVE="$CAPTURE_ROOT/rkllm-native-prefill-calibration-$STAMP.tar.gz"
tar -C "$TMP_DIR" -czf "$ARCHIVE" manifest.json native-prefill-results.json
printf 'PASS: native prefill calibration captured and source restored.\n'
printf 'Archive: %s\n' "$ARCHIVE"
printf 'Archive SHA-256: %s\n' "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf 'Temporary source backup: %s/service.py\n' "$BACKUP_DIR"
