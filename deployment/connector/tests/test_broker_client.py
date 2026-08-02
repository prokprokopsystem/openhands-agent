import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT_PATH = ROOT / "broker-client.py"
SPEC = importlib.util.spec_from_file_location("broker_client", CLIENT_PATH)
assert SPEC and SPEC.loader
CLIENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLIENT)


class BrokerClientContractTests(unittest.TestCase):
    def test_ssh_command_is_fixed_and_has_no_remote_command(self):
        command = CLIENT.SSH_COMMAND
        self.assertEqual(command[0], "/usr/bin/ssh")
        self.assertEqual(command[-1], "openhands-broker@10.89.0.1")
        self.assertIn("BatchMode=yes", command)
        self.assertIn("StrictHostKeyChecking=yes", command)
        self.assertIn("IdentitiesOnly=yes", command)
        self.assertIn("ClearAllForwardings=yes", command)
        self.assertIn("HostKeyAlgorithms=ssh-ed25519", command)
        self.assertNotIn("-c", command)

    def test_source_has_no_shell_or_environment_override(self):
        source = CLIENT_PATH.read_text(encoding="utf-8")
        self.assertNotIn("shell=True", source)
        self.assertNotIn("os.system", source)
        self.assertNotIn("bash -c", source)
        self.assertNotIn("SSH_ORIGINAL_COMMAND", source)
        self.assertNotIn("os.environ", source)

    def test_fixed_errors_are_bounded_json(self):
        response = CLIENT.fixed_error("test_error")
        parsed = json.loads(response)
        self.assertLessEqual(len(response), CLIENT.MAX_RESPONSE_BYTES)
        self.assertEqual(parsed["status"], "error")
        self.assertEqual(parsed["error"]["code"], "test_error")

    def test_bounded_reader_rejects_oversized_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "oversized.py"
            script.write_text("import sys; sys.stdin.buffer.read(); sys.stdout.write('x'*70000)\n", encoding="utf-8")
            process = subprocess.Popen(
                [sys.executable, str(script)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            with self.assertRaises(CLIENT.TransportError):
                CLIENT.communicate_bounded(process, b"{}")


class ConnectorDefinitionTests(unittest.TestCase):
    def test_dockerfile_pins_base_snapshot_and_package(self):
        source = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("@sha256:fc24163754bee2ab0115b117d57512cc01b4d99770e7ac17c3607e76290deeb6", source)
        self.assertIn("snapshot.debian.org/archive/debian/20260507T030000Z", source)
        self.assertIn("openssh-client=1:10.0p1-7+deb13u4", source)
        self.assertIn('test -n "${SOURCE_COMMIT}"', source)
        self.assertIn("USER openhands", source)


if __name__ == "__main__":
    unittest.main()
