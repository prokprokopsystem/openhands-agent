import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL = (ROOT / "install-canvas-connector.sh").read_text(encoding="utf-8")
VALIDATE = (ROOT / "validate-canvas-connector.sh").read_text(encoding="utf-8")
ROLLBACK = (ROOT / "rollback-canvas-connector.sh").read_text(encoding="utf-8")
ACCEPT = (ROOT / "accept-level-a-e2e.sh").read_text(encoding="utf-8")
DEPLOYMENT_ROOT = ROOT.parent


class ConnectorInstallationTests(unittest.TestCase):
    def test_install_is_anchored_to_completed_4d3(self):
        self.assertIn('BASE_COMMIT="f636ed90dd4c54ad83073a821f7f0111fa26f07a"', INSTALL)
        self.assertIn("Completed 4D.3 commit is not an ancestor", INSTALL)
        self.assertIn("Exact completed 4D.3 + pre-connector Canvas baseline verified", INSTALL)

    def test_preflight_has_no_mutating_connector_operations(self):
        body = INSTALL.split("preflight() {", 1)[1].split("build_image()", 1)[0]
        for forbidden in ("docker build", "systemctl stop", "systemctl start", "logger --tag", "create_snapshot"):
            self.assertNotIn(forbidden, body)

    def test_scope_excludes_protected_data(self):
        mutation_lines = [line for line in INSTALL.splitlines() if re.search(r"\b(install|rm|cp|mv|chown|chmod)\b", line)]
        joined = "\n".join(mutation_lines)
        for forbidden in ("/config", "work-workspace", "/docs", "conversations", "session", "Telegram", "backup"):
            self.assertNotIn(forbidden, joined)
        self.assertNotIn("broker-mini-server.key", INSTALL)

    def test_connector_mounts_are_read_only_and_exact(self):
        compose = (DEPLOYMENT_ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn("openhands-broker-v2/id_ed25519:/run/openhands-broker/client/id_ed25519:ro", compose)
        self.assertIn("/etc/openhands-broker/client_known_hosts:/run/openhands-broker/client/client_known_hosts:ro", compose)
        self.assertNotIn("/etc/openhands-broker:/", compose)

    def test_firewall_allows_only_exact_broker_endpoint(self):
        firewall = (DEPLOYMENT_ROOT / "network" / "apply-egress-rules.sh").read_text(encoding="utf-8")
        self.assertIn('BROKER_SOURCE="10.89.0.2/32"', firewall)
        self.assertIn('BROKER_ENDPOINT="10.89.0.1/32"', firewall)
        self.assertNotIn("-p tcp --dport 22 -j RETURN", firewall)

    def test_rollback_restores_snapshot_and_preserves_broker(self):
        self.assertIn("PRE-CONNECTOR.sha256", ROLLBACK)
        self.assertIn('rm -rf -- "${BASE}/deployment/connector"', ROLLBACK)
        self.assertNotIn("/usr/local/lib/openhands-broker", ROLLBACK)
        self.assertNotIn("openhands-broker-v2", ROLLBACK)
        self.assertIn("deployment/network/README.md", INSTALL)
        self.assertIn("deployment/scripts/validate-static.sh", INSTALL)

    def test_validation_and_e2e_cover_positive_and_negative_paths(self):
        self.assertIn('"tool":"core.ping"', VALIDATE)
        self.assertIn('"tool":"mini_server.health"', ACCEPT)
        self.assertIn('"path":"/etc"', ACCEPT)
        self.assertIn("original_command_forbidden", ACCEPT)
        self.assertIn("arguments_forbidden", ACCEPT)
        self.assertIn("check-egress.sh", VALIDATE)

    def test_recovery_requires_real_rollback_reinstall_cycle(self):
        recovery = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("install → rollback → reinstall", recovery)
        self.assertIn("de2244dd", recovery)
        self.assertIn("accept-level-a-e2e.sh", recovery)


if __name__ == "__main__":
    unittest.main()
