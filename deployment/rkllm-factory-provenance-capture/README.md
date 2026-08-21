# RKLLM WSGI factory provenance capture

This read-only pilot captures the SHA-256 and Git provenance for the active
`src/aibrain_rkllm/wsgi_factory.py` file. It does not edit source, configuration,
service state, or runtime files. Its only output is a sanitized evidence archive
under `/srv/aibrain/test/captures/`.

Use it when a guarded installer detects that the factory identity differs from the
captured baseline. Review the archive before changing the installer’s expected hash.
