from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ServiceConfig:
    model_path: Path
    library_path: Path
    host: str = "127.0.0.1"
    port: int = 8081
    target_platform: str = "rk3588"
    max_context_length: int = 4096

    def validate(self) -> None:
        if self.host != "127.0.0.1":
            raise ValueError("RKLLM service must bind to loopback only")
        if self.port != 8081:
            raise ValueError("RKLLM service contract uses port 8081")
        if self.target_platform != "rk3588":
            raise ValueError("target platform must be rk3588")
        if self.max_context_length != 4096:
            raise ValueError("context length must remain 4096 until revalidated")
