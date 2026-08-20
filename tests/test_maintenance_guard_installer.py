import hashlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "aibrain_maintenance.py"
INSTALLER = ROOT / "run.sh"


class InstallerContractTests(unittest.TestCase):
    def test_installer_pins_the_exact_source(self) -> None:
        script = INSTALLER.read_text()
        match = re.search(r'^SOURCE_SHA256="([0-9a-f]{64})"$', script, re.MULTILINE)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), hashlib.sha256(SOURCE.read_bytes()).hexdigest())

    def test_installer_fetches_only_deployed_source_and_contract(self) -> None:
        script = INSTALLER.read_text()
        self.assertIn('SOURCE_PATH="deployment/maintenance-guard/aibrain_maintenance.py"', script)
        self.assertIn('CONTRACT_PATH="deployment/maintenance-guard/AI_TOOL_CONTRACT.md"', script)
        contract = ROOT / "AI_TOOL_CONTRACT.md"
        match = re.search(r'^CONTRACT_SHA256="([0-9a-f]{64})"$', script, re.MULTILINE)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), hashlib.sha256(contract.read_bytes()).hexdigest())

    def test_installer_has_no_unsafe_production_mutation(self) -> None:
        script = INSTALLER.read_text()
        self.assertNotIn("sudo", script)
        self.assertNotIn("systemctl", script)
        self.assertNotIn("apt ", script)
        self.assertNotIn("curl |", script)


if __name__ == "__main__":
    unittest.main()
