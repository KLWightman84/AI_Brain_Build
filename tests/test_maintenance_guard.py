import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout


REPO_ROOT = Path(__file__).parents[1]
GUARD_DIR = REPO_ROOT / "deployment" / "maintenance-guard"
if not GUARD_DIR.is_dir():
    GUARD_DIR = REPO_ROOT
MODULE_PATH = GUARD_DIR / "aibrain_maintenance.py"
SPEC = importlib.util.spec_from_file_location("aibrain_maintenance", MODULE_PATH)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)


def valid_request() -> dict[str, object]:
    return {
        "schema": 1,
        "kind": "repair",
        "repository": "KLWightman84/AI_Brain_Build",
        "commit": "a" * 40,
        "script": "deployment/example-repair/run.sh",
        "sha256": "b" * 64,
        "summary": "Fix a verified, isolated failure.",
        "verification": ["unit tests pass", "health endpoint passes"],
    }


class MaintenanceGuardTests(unittest.TestCase):
    def test_release_request_is_strict_and_immutable(self) -> None:
        request = guard.parse_release_request(valid_request(), guard.default_policy())
        self.assertTrue(guard.release_url(request).endswith("/" + request.commit + "/" + request.script))
        command = guard.render_owner_command(request)
        self.assertIn("raw.githubusercontent.com/KLWightman84/AI_Brain_Build/", command)
        self.assertIn("sha256sum -c", command)
        self.assertNotIn("curl |", command)

    def test_release_request_rejects_unapproved_or_floating_inputs(self) -> None:
        for field, value in (("repository", "other/repo"), ("commit", "main"), ("script", "../run.sh"), ("sha256", "x" * 64)):
            raw = valid_request()
            raw[field] = value
            with self.assertRaises(guard.GuardError, msg=field):
                guard.parse_release_request(raw, guard.default_policy())

    def test_snapshot_uses_only_fixed_commands_and_redacts_output(self) -> None:
        seen: list[tuple[str, ...]] = []

        def runner(command: tuple[str, ...]) -> dict[str, object]:
            seen.append(command)
            return {"ok": True, "stdout": "token=not-for-export"}

        snapshot = guard.collect_snapshot(guard.default_policy(), runner=runner)
        self.assertIn(("systemctl", "--user", "is-active", "aibrain-rkllm.service"), seen)
        self.assertTrue(all(";" not in part for command in seen for part in command))
        self.assertTrue(snapshot["limitations"])
        self.assertNotIn("not-for-export", json.dumps(snapshot))

    def test_plan_output_requires_owner_approval(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            request_path = Path(directory) / "request.json"
            request_path.write_text(json.dumps(valid_request()))
            output = io.StringIO()
            with redirect_stdout(output):
                rc = guard.main(["--policy", str(Path(directory) / "missing-policy.json"), "plan", str(request_path)])
        self.assertEqual(rc, 0)
        parsed = json.loads(output.getvalue())
        self.assertIs(parsed["requires_owner_approval"], True)
        self.assertIn("AI must not execute", parsed["guardrails"][0])


if __name__ == "__main__":
    unittest.main()
