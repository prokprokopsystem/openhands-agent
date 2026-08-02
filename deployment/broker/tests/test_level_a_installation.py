import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL = (ROOT / "install-level-a-v2.sh").read_text(encoding="utf-8")
VALIDATE = (ROOT / "validate-level-a-v2.sh").read_text(encoding="utf-8")
ROLLBACK = (ROOT / "rollback-level-a-v2.sh").read_text(encoding="utf-8")


class LevelAInstallationTests(unittest.TestCase):
    def test_update_is_anchored_to_completed_4d2(self):
        self.assertIn('BASE_COMMIT="f9c97c4cc113b081f19c455bd193e014fa3d7585"', INSTALL)
        self.assertIn("git merge-base --is-ancestor", INSTALL)
        self.assertIn("Installed broker is not the exact completed 4D.2 baseline", INSTALL)
        preflight_body = INSTALL.split("preflight() {", 1)[1].split("create_snapshot()", 1)[0]
        self.assertNotIn("deployment/broker/validate-level-a-v2.sh", preflight_body)

    def test_sudo_is_fixed_runas_adapter_without_arguments(self):
        expected = '${BROKER_USER} ALL=(${ADAPTER_USER}) NOPASSWD: ${BROKER_LIB}/adapters/mini-server-adapter \\\"\\\"'
        self.assertIn(expected, INSTALL)
        self.assertIn('"/usr/bin/sudo",', (ROOT / "broker_core.py").read_text(encoding="utf-8"))
        self.assertNotRegex(INSTALL, r"NOPASSWD:.*\*")

    def test_update_does_not_touch_base_canvas_lifecycle(self):
        mutation_lines = [
            line for line in INSTALL.splitlines()
            if re.search(r"\b(install|rm|mv|cp|chown|chmod)\b", line)
        ]
        joined = "\n".join(mutation_lines)
        for forbidden in ("compose.yaml", "openhands-agent.service", "prepare.sh", "config/", "work-workspace", "docs/"):
            self.assertNotIn(forbidden, joined)

    def test_rollback_removes_only_4d3_artifacts_and_restores_snapshot(self):
        self.assertIn('"${SNAPSHOT}/broker_core.py"', INSTALL)
        self.assertIn('"${SNAPSHOT}/install-state.json"', INSTALL)
        self.assertIn('rm -f -- "${BROKER_LIB}/adapters/mini-server-adapter"', INSTALL)
        self.assertIn("verify_base_canvas", INSTALL)
        self.assertIn('"${BROKER_STATE}/updates/"*-4d3-to-*', ROLLBACK)
        self.assertIn('"level_a_update_snapshot"', ROLLBACK)
        self.assertIn('rm -f -- "${BROKER_LIB}/adapters/mini-server-adapter"', ROLLBACK)
        for forbidden in ("compose.yaml", "openhands-agent.service", "config/", "work-workspace", "docs/"):
            self.assertNotIn(forbidden, ROLLBACK)

    def test_validator_checks_real_level_a_and_denial(self):
        self.assertIn('"tool":"mini_server.health"', VALIDATE)
        self.assertIn('"tool":"mini_server.filesystem_usage"', VALIDATE)
        self.assertIn('"path":"/etc"', VALIDATE)
        self.assertIn("Base Canvas files changed", VALIDATE)


if __name__ == "__main__":
    unittest.main()
