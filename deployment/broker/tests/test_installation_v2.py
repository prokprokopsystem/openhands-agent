import hashlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
INSTALL = (ROOT / "install-broker-v2.sh").read_text(encoding="utf-8")
VALIDATE = (ROOT / "validate-install-v2.sh").read_text(encoding="utf-8")
ROLLBACK = (ROOT / "rollback-broker-v1.sh").read_text(encoding="utf-8")
UNINSTALL = (ROOT / "uninstall-broker-v2.sh").read_text(encoding="utf-8")
KEYPAIR_VERIFIER = ROOT / "verify-keypair-fingerprint.sh"


def function_body(source: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}\(\) \{{\n(.*?)^\}}\n", source, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"function not found: {name}")
    return match.group(1)


class FrozenBaselineTests(unittest.TestCase):
    EXPECTED_BLOBS = {
        "deployment/broker/broker-wrapper.sh": "decb5e6c2c5bcc6eeb32b345da4b434ab3e1f039",
        "deployment/broker/journal-logs.sh": "9c6e79f7ce8246dba108ef11661b17d69aef2780",
        "deployment/broker/tools.yaml": "f693aad33f34aeebd838122f654a734d4ac7043d",
    }

    def test_frozen_blob_guards_match_branch(self):
        for path, expected in self.EXPECTED_BLOBS.items():
            actual = subprocess.check_output(
                ["git", "rev-parse", f"fix/canonical-deployment:{path}"],
                cwd=REPO,
                text=True,
            ).strip()
            self.assertEqual(actual, expected)
            self.assertIn(expected, INSTALL)

    def test_frozen_policy_hash_guards_are_derived_from_branch(self):
        frozen = subprocess.check_output(
            ["git", "show", "fix/canonical-deployment:deployment/broker/setup-broker.sh"],
            cwd=REPO,
            text=True,
        )
        for marker, constant in (
            ("SUDO", "OLD_SUDOERS_SHA256"),
            ("SSHD", "OLD_SSHD_SHA256"),
        ):
            match = re.search(
                rf"^cat > [^\n]* << '{marker}'\n(.*?)^{marker}$",
                frozen,
                re.MULTILINE | re.DOTALL,
            )
            self.assertIsNotNone(match, f"missing frozen {marker} heredoc")
            actual = hashlib.sha256(match.group(1).encode()).hexdigest()
            guarded = re.search(rf'{constant}="([0-9a-f]{{64}})"', INSTALL)
            self.assertIsNotNone(guarded, f"missing {constant}")
            self.assertEqual(actual, guarded.group(1))

    def test_all_legacy_checks_precede_snapshot_and_mutation(self):
        main = INSTALL.rsplit('\n[ "$(id -u)" -eq 0 ]', 1)[1]
        self.assertLess(main.index("preflight_legacy"), main.index("install_v2"))
        install_body = function_body(INSTALL, "install_v2")
        self.assertLess(install_body.index("create_snapshot"), install_body.index("MUTATION_STARTED=true"))
        self.assertLess(install_body.index("MUTATION_STARTED=true"), install_body.index('rm -rf -- "${BROKER_LIB}"'))

    def test_unexpected_legacy_inventory_fails_closed(self):
        preflight = function_body(INSTALL, "preflight_legacy")
        self.assertIn("assert_exact_inventory", preflight)
        self.assertIn("Legacy sudoers differs from frozen baseline", preflight)
        self.assertIn("Legacy sshd drop-in differs from frozen baseline", preflight)
        self.assertIn("Unexpected pre-existing adapter identity", preflight)
        inventory = function_body(INSTALL, "assert_exact_inventory")
        self.assertIn("client_known_hosts\\nsecrets\\ntools.yaml", inventory)
        self.assertIn("Legacy secrets directory is not empty", inventory)

    def test_preflight_only_does_not_create_lock_tempfiles_or_audit(self):
        main = INSTALL.rsplit('\n[ "$(id -u)" -eq 0 ]', 1)[1]
        preflight_exit = main.index('if [ "${PREFLIGHT_ONLY}" = true ]')
        before_exit = main[:preflight_exit]
        for forbidden in ("install -d", "migration.lock", "logger --tag", "mktemp"):
            self.assertNotIn(forbidden, before_exit)
        preflight = function_body(INSTALL, "preflight_legacy")
        self.assertNotIn("mktemp", preflight)
        self.assertNotIn("logger", preflight)


class ProtectedBoundaryTests(unittest.TestCase):
    PROTECTED_PREFIXES = (
        "/srv/openhands-agent/config",
        "/srv/openhands-agent/work-workspace",
        "/srv/openhands-agent/docs",
        "/srv/openhands-agent/deployment/compose.yaml",
        "/srv/openhands-agent/deployment/scripts",
        "/usr/local/bin/openhands-backup.sh",
    )

    def test_runtime_code_does_not_reference_base_canvas_targets(self):
        for line in INSTALL.splitlines():
            if not re.search(r"\b(rm|mv|cp|install|chmod|chown|truncate|tee)\b", line):
                continue
            for prefix in self.PROTECTED_PREFIXES:
                self.assertNotIn(prefix, line)

    def test_legacy_client_keys_are_never_mutation_targets(self):
        for source in (INSTALL, VALIDATE, ROLLBACK, UNINSTALL):
            for line in source.splitlines():
                if "LEGACY_CLIENT_KEY" in line or "broker-mini-server.key" in line:
                    self.assertNotRegex(line, r"\b(rm|mv|cp|install|chmod|chown)\b")

    def test_separate_v2_key_is_created_with_canvas_uid_and_strict_mode(self):
        keygen = function_body(INSTALL, "ensure_v2_keypair")
        self.assertIn("ssh-keygen -q -t ed25519", keygen)
        self.assertIn("-o 10001 -g 10001 -m 0600", keygen)
        self.assertIn("V2_CLIENT_KEY", keygen)
        self.assertNotIn("LEGACY_CLIENT_KEY", keygen)
        self.assertIn("10001:10001:600", VALIDATE)
        self.assertIn("Broker v2 private key is missing or symlinked", INSTALL)
        self.assertIn("Broker v2 private key is missing or symlinked", VALIDATE)

    def test_keypair_verifier_uses_fingerprints_and_rejects_real_mismatch(self):
        verifier = KEYPAIR_VERIFIER.read_text(encoding="utf-8")
        self.assertIn('ssh-keygen -y -f "${private_key}"', verifier)
        self.assertIn("ssh-keygen -lf - -E sha256", verifier)
        self.assertIn('ssh-keygen -lf "${public_key}" -E sha256', verifier)
        self.assertIn("KEYPAIR_VERIFIER", INSTALL)
        self.assertIn("KEYPAIR_VERIFIER", VALIDATE)

        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first"
            second = Path(directory) / "second"
            for key in (first, second):
                subprocess.run(
                    ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                    check=True,
                )

            matching = subprocess.run(
                [str(KEYPAIR_VERIFIER), str(first), f"{first}.pub"],
                text=True,
                capture_output=True,
            )
            self.assertEqual(matching.returncode, 0, matching.stderr)

            mismatched = subprocess.run(
                [str(KEYPAIR_VERIFIER), str(first), f"{second}.pub"],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(mismatched.returncode, 0)
            self.assertIn("SSH keypair fingerprint mismatch", mismatched.stderr)

    def test_uninstall_and_rollback_do_not_reference_base_canvas(self):
        for source in (ROLLBACK, UNINSTALL):
            self.assertNotRegex(source, r"\b(rm|mv|cp|install|chmod|chown)\b[^\n]*/srv/openhands-agent")
            self.assertNotIn("openhands-agent.service", source)

    def test_no_v2_sudo_grants_are_installed(self):
        self.assertNotIn("NOPASSWD:", INSTALL)
        self.assertIn('rm -f -- "${SUDOERS_FILE}"', INSTALL)
        self.assertIn("Broker retains a sudo command grant", INSTALL)
        self.assertIn("sudo -l -U", INSTALL)


class IsolationContractTests(unittest.TestCase):
    ADAPTERS = ("mini-server", "vps", "n8n", "github", "nextcloud", "notion", "amnesia")

    def test_all_adapter_identities_are_declared(self):
        for adapter in self.ADAPTERS:
            self.assertIn(adapter, INSTALL)
            self.assertIn(adapter, VALIDATE)

    def test_adapter_accounts_are_non_login_and_secret_dirs_are_isolated(self):
        self.assertIn("--shell /usr/sbin/nologin", INSTALL)
        self.assertIn('"${BROKER_ETC}/secrets.d/${adapter}"', INSTALL)
        self.assertIn('-o root -g "${user}" -m 0750', INSTALL)
        self.assertIn("Broker core has unexpected group memberships", VALIDATE)
        self.assertIn("Adapter state isolation failed", VALIDATE)
        self.assertIn("Adapter credential isolation failed", VALIDATE)
        self.assertIn("Broker core can read the broker v2 client private key", VALIDATE)
        self.assertIn("Adapter can read the Canvas broker client key", VALIDATE)
        self.assertIn('-m 0711 "${BROKER_STATE}" "${BROKER_STATE}/adapters"', INSTALL)

    def test_level_c_directories_are_root_only(self):
        for name in ("approvals", "inflight", "consumed"):
            self.assertIn(f"/run/openhands-broker/{name}", INSTALL)
            self.assertIn(f"/run/openhands-broker/{name}", VALIDATE)
        self.assertIn("-o root -g root -m 0700", INSTALL)

    def test_forced_command_is_v2_launcher(self):
        expected = "/usr/local/lib/openhands-broker/bin/broker-launcher"
        self.assertIn(f"ForceCommand {expected}", INSTALL)
        self.assertIn(f"forcecommand {expected}", VALIDATE)
        self.assertIn('from="%s",restrict,command="%s/bin/broker-launcher"', INSTALL)

    def test_pinned_trust_is_derived_from_actual_ed25519_host_key(self):
        self.assertIn("HOST_PUBLIC_KEY", INSTALL)
        self.assertIn('host_public%% *}" = "ssh-ed25519', INSTALL)
        self.assertIn("Pinned host trust differs from actual ED25519 host key", INSTALL)


class TransactionTests(unittest.TestCase):
    def test_snapshot_preserves_original_metadata(self):
        snapshot = function_body(INSTALL, "create_snapshot")
        self.assertIn("cp -a", snapshot)
        self.assertNotIn("chmod -R", snapshot)
        self.assertIn("mkdir -m 0700", snapshot)
        self.assertIn("write_base_canvas_manifest", snapshot)

    def test_base_canvas_hashes_are_checked_after_install_and_rollback(self):
        self.assertIn("verify_base_canvas_manifest", INSTALL)
        self.assertIn("BASE-CANVAS.sha256", VALIDATE)
        self.assertIn("BASE-CANVAS.sha256", ROLLBACK)
        self.assertIn("BASE-CANVAS.sha256", UNINSTALL)

    def test_error_trap_restores_only_broker_artifacts(self):
        rollback = function_body(INSTALL, "restore_snapshot")
        self.assertIn('"${SNAPSHOT}/lib"', rollback)
        self.assertIn('"${SNAPSHOT}/etc"', rollback)
        self.assertIn('"${SNAPSHOT}/home"', rollback)
        self.assertNotIn("/srv/openhands-agent", rollback)
        self.assertIn("systemctl reload ssh.service", rollback)

    def test_manual_rollback_restricts_snapshot_path(self):
        self.assertIn('"${STATE_ROOT}/migrations/"*', ROLLBACK)
        self.assertIn("root:root:700", ROLLBACK)
        self.assertIn("openhands-broker-v1-snapshot", ROLLBACK)
        self.assertIn("--confirm", ROLLBACK)

    def test_uninstall_requires_marker_and_confirmation(self):
        self.assertIn("--confirm", UNINSTALL)
        self.assertIn("Broker v2 install marker missing", UNINSTALL)
        self.assertIn("migrations and all protected client key files preserved", UNINSTALL)


if __name__ == "__main__":
    unittest.main()
