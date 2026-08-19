#!/usr/bin/env python3
"""Run the clean RKLLM HTTP service on its fixed loopback-only contract."""

from __future__ import annotations

import argparse
import signal
from pathlib import Path

from aibrain_rkllm.config import ServiceConfig
from aibrain_rkllm.service import RKLLMBackend, create_app


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = ServiceConfig(model_path=args.model, library_path=args.library)
    config.validate()

    backend = RKLLMBackend.load(config.library_path, config.model_path)
    app = create_app(backend)

    def shutdown_handler(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    try:
        app.run(
            host=config.host,
            port=config.port,
            threaded=False,
            debug=False,
            use_reloader=False,
        )
    finally:
        backend.close()
        print("RKLLM service model released", flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
