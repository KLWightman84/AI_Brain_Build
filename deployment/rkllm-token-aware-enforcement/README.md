# RKLLM token-aware context enforcement

This installation candidate replaces the active 2,400-word heuristic with exact counts from the
captured Qwen tokenizer, certified against native RKLLM prefill telemetry on the active 4,096-token
model. Its conservative input budget is:

`4096 − requested max_new_tokens − 46 calibrated reserve`

System instructions and the current user/tool input are mandatory. The installer rejects a request
with HTTP 400 before inference if those mandatory parts exceed the budget. It adds prior
conversation as whole units from newest backwards; it adds `dawn_context` only after fitting that
conversation, as lower-priority reference material. Nothing is sliced by word or character count.

The installer copies the verified tokenizer wheel and JSON into a production runtime directory,
uses a dedicated systemd user-service drop-in to expose that runtime, applies exactly three
hash-guarded adapter files, and runs unit, startup, loopback, 768-token, and oversize-rejection
checks. A failure restores all three source files, removes the new drop-in/runtime, reloads the
user service, and verifies the original source hashes.

Run `bash deployment/rkllm-token-aware-enforcement/test_run.sh` before publishing. A successful
installation is still a pilot; chat-turn and repeated-request acceptance testing follows before
promotion.
