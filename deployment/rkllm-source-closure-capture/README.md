# RKLLM Source-Closure Capture

This read-only pilot closes the evidence gap between the running RKLLM adapter
and a future reviewed recovery candidate. It captures only the known active
changes to `src/aibrain_rkllm/service.py` and `tests/test_service.py`.

The capture fails closed if another tracked file changed or an untracked file
is not a known generated Python artifact. It records the base commit, source
diff, current hashes, Python compilation, direct unit-test results, and a
sanitized manifest. It does not include configuration, models, service
environment values, logs, or secrets; it does not restart any service.

After review, the archive—not the live working tree—will be the evidence for a
separate recovery-candidate build on an isolated GitHub branch.
