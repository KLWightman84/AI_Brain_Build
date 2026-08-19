# AI Brain Build

Clean, testable build components for the Orange Pi 5 Plus (RK3588) AI platform.

## First component: RKLLM service

The RKLLM service is a clean implementation candidate derived from audited behavior of the preserved `dawn_rkllm_server.py` reference. It must:

- run only as the `ai_brain` user;
- bind only to `127.0.0.1:8081`;
- use one explicit 4B RKLLM model path;
- use the RK3588 NPU runtime;
- release the native RKLLM handle exactly once;
- pass unit, repeated-request, shutdown/restart, and DAWN-adjacent integration tests before production use.

The preservation repository is evidence only; this repository holds new production-build code and tests.
