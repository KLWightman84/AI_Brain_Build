#!/usr/bin/env python3
"""Human-approved maintenance guard for the AI Brain pilot.

This program is deliberately *not* a general shell.  It gathers a narrow,
sanitized health snapshot and validates immutable GitHub deployment requests.
It never executes an upgrade, restarts a service, installs a package, reads a
secret, or accepts a command supplied by an LLM.  The final deployment command
is rendered for the owner to inspect and run outside the AI conversation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable

SCHEMA_VERSION = 1
DEFAULT_POLICY_PATH = Path("/srv/aibrain/production/maintenance/policy.json")
DEFAULT_OUTPUT_DIR = Path("/srv/aibrain/production/maintenance/evidence")
DEFAULT_REPOSITORY = "KLWightman84/AI_Brain_Build"
DEFAULT_SERVICES = ("aibrain-rkllm.service", "dawn-stage3-webui-tts.service")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SCRIPT_RE = re.compile(r"^deployment/[A-Za-z0-9][A-Za-z0-9._-]*/run\.sh$")
SENSITIVE_RE = re.compile(
    r"(?i)(token|password|secret|api[_-]?key|authorization)\s*([:=])\s*[^\s,;]+"
)


class GuardError(RuntimeError):
    """Raised for an invalid request or unavailable safe observation."""


def default_policy() -> dict[str, Any]:
    return {
        "schema": SCHEMA_VERSION,
        "approved_repository": DEFAULT_REPOSITORY,
        "services": list(DEFAULT_SERVICES),
        "health_endpoints": {
            "rkllm": "http://127.0.0.1:8081/healthz",
            "webui": "http://127.0.0.1:3000/",
        },
        "project_root": "/srv/aibrain/production/apps/AI_Brain_Build",
        "allowed_release_kinds": ["repair", "upgrade", "pilot"],
    }


def load_policy(path: Path) -> dict[str, Any]:
    if not path.exists():
        return default_policy()
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GuardError(f"policy cannot be read: {error}") from error
    if not isinstance(policy, dict) or policy.get("schema") != SCHEMA_VERSION:
        raise GuardError("policy schema is unsupported")
    for field in ("approved_repository", "services", "health_endpoints", "project_root"):
        if field not in policy:
            raise GuardError(f"policy is missing {field!r}")
    return policy


def redact(text: str) -> str:
    """Remove common credential assignments without attempting to log configs."""
    return SENSITIVE_RE.sub("[REDACTED]", text).replace("\x00", "")


def run_fixed(command: tuple[str, ...], timeout: float = 8.0) -> dict[str, Any]:
    """Run a fixed argument vector; no shell, interpolation, or LLM input."""
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env={"PATH": "/usr/bin:/bin"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": redact(str(error))}
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": redact(completed.stdout.strip())[:4096],
        "stderr": redact(completed.stderr.strip())[:1024],
    }


def sanitize_value(value: Any) -> Any:
    """Apply redaction again at the evidence boundary (defense in depth)."""
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [sanitize_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): sanitize_value(item) for key, item in value.items()}
    return value


def http_probe(url: str, timeout: float = 4.0) -> dict[str, Any]:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(1024).decode("utf-8", errors="replace")
            return {"ok": 200 <= response.status < 400, "status": response.status, "body": redact(body)}
    except (urllib.error.URLError, OSError) as error:
        return {"ok": False, "error": redact(str(error))}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_snapshot(policy: dict[str, Any], runner: Callable[[tuple[str, ...]], dict[str, Any]] = run_fixed) -> dict[str, Any]:
    """Collect only fixed, read-only health facts needed for a maintenance plan."""
    def safe_run(command: tuple[str, ...]) -> dict[str, Any]:
        return sanitize_value(runner(command))

    services: dict[str, Any] = {}
    for service in policy["services"]:
        if not isinstance(service, str) or not service.endswith(".service"):
            raise GuardError("policy has an invalid service name")
        services[service] = {
            "active": safe_run(("systemctl", "--user", "is-active", service)),
            "enabled": safe_run(("systemctl", "--user", "is-enabled", service)),
        }

    project_root = Path(policy["project_root"])
    git: dict[str, Any]
    if project_root.is_dir():
        git = {
            "head": safe_run(("git", "-C", str(project_root), "rev-parse", "HEAD")),
            "status": safe_run(("git", "-C", str(project_root), "status", "--short")),
        }
    else:
        git = {"ok": False, "error": "project root is unavailable"}

    endpoints = policy["health_endpoints"]
    health = {name: http_probe(url) for name, url in endpoints.items() if isinstance(url, str)}
    return {
        "schema": SCHEMA_VERSION,
        "kind": "maintenance_snapshot",
        "collected_at": int(time.time()),
        "services": services,
        "health": health,
        "listeners": safe_run(("ss", "-ltnH")),
        "disk": safe_run(("df", "-h", "/srv/aibrain")),
        "memory": safe_run(("free", "-h")),
        "git": git,
        "limitations": [
            "No logs, configuration contents, environment values, or secrets were collected.",
            "This snapshot cannot authorize a change or prove an upgrade is safe.",
        ],
    }


@dataclass(frozen=True)
class ReleaseRequest:
    schema: int
    kind: str
    repository: str
    commit: str
    script: str
    sha256: str
    summary: str
    verification: list[str]


def parse_release_request(raw: object, policy: dict[str, Any]) -> ReleaseRequest:
    if not isinstance(raw, dict):
        raise GuardError("release request must be a JSON object")
    required = ("schema", "kind", "repository", "commit", "script", "sha256", "summary", "verification")
    missing = [name for name in required if name not in raw]
    if missing:
        raise GuardError(f"release request is missing: {', '.join(missing)}")
    if raw["schema"] != SCHEMA_VERSION:
        raise GuardError("release request schema is unsupported")
    if raw["repository"] != policy["approved_repository"]:
        raise GuardError("repository is not approved by policy")
    if raw["kind"] not in policy.get("allowed_release_kinds", []):
        raise GuardError("release kind is not approved by policy")
    if not isinstance(raw["commit"], str) or not COMMIT_RE.fullmatch(raw["commit"]):
        raise GuardError("commit must be a full 40-character lowercase SHA")
    if not isinstance(raw["script"], str) or not SCRIPT_RE.fullmatch(raw["script"]):
        raise GuardError("script must be deployment/<name>/run.sh")
    if not isinstance(raw["sha256"], str) or not SHA256_RE.fullmatch(raw["sha256"]):
        raise GuardError("sha256 must be a lowercase SHA-256 digest")
    if not isinstance(raw["summary"], str) or not raw["summary"].strip() or len(raw["summary"]) > 500:
        raise GuardError("summary must be 1-500 characters")
    verification = raw["verification"]
    if not isinstance(verification, list) or not verification or not all(isinstance(item, str) and item.strip() for item in verification):
        raise GuardError("verification must be a non-empty list of strings")
    return ReleaseRequest(
        schema=raw["schema"], kind=raw["kind"], repository=raw["repository"],
        commit=raw["commit"], script=raw["script"], sha256=raw["sha256"],
        summary=raw["summary"].strip(), verification=verification,
    )


def release_url(request: ReleaseRequest) -> str:
    return f"https://raw.githubusercontent.com/{request.repository}/{request.commit}/{request.script}"


def plan_digest(request: ReleaseRequest) -> str:
    encoded = json.dumps(asdict(request), sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def render_owner_command(request: ReleaseRequest) -> str:
    """Render, but never execute, the one-command immutable release pattern."""
    digest = plan_digest(request)
    temp = f"/tmp/aibrain-maintenance-{digest[:12]}.sh"
    return (
        f"curl --fail --location --silent --show-error {release_url(request)} -o {temp} && "
        f"printf '%s  %s\\n' '{request.sha256}' '{temp}' | sha256sum -c - && bash {temp}"
    )


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o640)
    temporary.replace(path)


def command_inspect(args: argparse.Namespace) -> int:
    policy = load_policy(Path(args.policy))
    snapshot = collect_snapshot(policy)
    if args.output:
        write_json(Path(args.output), snapshot)
    else:
        print(json.dumps(snapshot, indent=2, sort_keys=True))
    return 0


def command_plan(args: argparse.Namespace) -> int:
    policy = load_policy(Path(args.policy))
    try:
        raw = json.loads(Path(args.request).read_text(encoding="utf-8"))
        request = parse_release_request(raw, policy)
    except (OSError, json.JSONDecodeError, GuardError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    plan = {
        "schema": SCHEMA_VERSION,
        "kind": "maintenance_plan",
        "plan_sha256": plan_digest(request),
        "request": asdict(request),
        "requires_owner_approval": True,
        "owner_command": render_owner_command(request),
        "guardrails": [
            "The AI must not execute this command or claim it was executed.",
            "The owner must inspect the immutable GitHub commit, command hash, scope, rollback, and verification before running it.",
            "Any sudo, secret, network-exposure, package-removal, reboot, or destructive action requires a separately reviewed deployment artifact.",
        ],
    }
    if args.output:
        write_json(Path(args.output), plan)
    else:
        print(json.dumps(plan, indent=2, sort_keys=True))
    return 0


def command_install_policy(args: argparse.Namespace) -> int:
    path = Path(args.policy)
    if path.exists() and not args.force:
        print(f"ERROR: policy exists: {path}", file=sys.stderr)
        return 2
    write_json(path, default_policy())
    print(f"Created policy: {path}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Human-approved AI Brain maintenance guard")
    parser.add_argument("--policy", default=str(DEFAULT_POLICY_PATH), help="policy JSON path")
    subcommands = parser.add_subparsers(dest="command", required=True)
    inspect_parser = subcommands.add_parser("inspect", help="collect a sanitized read-only health snapshot")
    inspect_parser.add_argument("--output", help="write snapshot JSON instead of stdout")
    inspect_parser.set_defaults(handler=command_inspect)
    plan_parser = subcommands.add_parser("plan", help="validate an immutable release request and render owner command")
    plan_parser.add_argument("request", help="release-request JSON file")
    plan_parser.add_argument("--output", help="write plan JSON instead of stdout")
    plan_parser.set_defaults(handler=command_plan)
    policy_parser = subcommands.add_parser("install-policy", help="write the initial restrictive policy")
    policy_parser.add_argument("--force", action="store_true", help="replace an existing policy")
    policy_parser.set_defaults(handler=command_install_policy)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except GuardError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
