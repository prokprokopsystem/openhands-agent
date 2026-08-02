import json
import os
import subprocess
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "bin" / "broker-launcher"
ADAPTER = ROOT / "adapters" / "core-adapter"


class ProcessBoundaryTests(unittest.TestCase):
    def test_launcher_rejects_original_command(self):
        env = dict(os.environ)
        env["SSH_ORIGINAL_COMMAND"] = "core.ping command=id"
        completed = subprocess.run([str(LAUNCHER)], input=b"{}", capture_output=True, env=env, timeout=5)
        response = json.loads(completed.stdout)
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(response["error"]["code"], "original_command_forbidden")

    def test_launcher_rejects_arguments(self):
        completed = subprocess.run([str(LAUNCHER), "core.ping"], capture_output=True, timeout=5)
        response = json.loads(completed.stdout)
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(response["error"]["code"], "arguments_forbidden")

    def test_launcher_uses_clean_environment(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn("exec /usr/bin/env -i", source)
        self.assertNotIn("dirname", source)
        self.assertNotIn("eval", source)
        self.assertNotIn("bash -c", source)
        self.assertLess(source.index("PATH=/usr/bin:/bin"), source.index("broker_root="))

    def test_core_adapter_ping(self):
        payload = {
            "version": 1,
            "request_id": str(uuid.uuid4()),
            "target": "core",
            "operation": "ping",
            "params": {},
        }
        completed = subprocess.run([str(ADAPTER)], input=json.dumps(payload).encode(), capture_output=True, timeout=5)
        response = json.loads(completed.stdout)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(response["result"]["pong"], True)
        self.assertEqual(
            set(response), {"status", "result", "result_code", "verify", "rollback"}
        )
        self.assertEqual(response["verify"]["status"], "not_applicable")
        self.assertEqual(response["rollback"]["status"], "not_applicable")

    def test_core_adapter_rejects_unknown_operation(self):
        payload = {
            "version": 1,
            "request_id": str(uuid.uuid4()),
            "target": "core",
            "operation": "shell",
            "params": {},
        }
        completed = subprocess.run([str(ADAPTER)], input=json.dumps(payload).encode(), capture_output=True, timeout=5)
        self.assertNotEqual(completed.returncode, 0)

    def test_core_adapter_rejects_target_mismatch(self):
        payload = {
            "version": 1,
            "request_id": str(uuid.uuid4()),
            "target": "vps",
            "operation": "ping",
            "params": {},
        }
        completed = subprocess.run([str(ADAPTER)], input=json.dumps(payload).encode(), capture_output=True, timeout=5)
        self.assertNotEqual(completed.returncode, 0)

    def test_core_adapter_rejects_boolean_version(self):
        payload = {
            "version": True,
            "request_id": str(uuid.uuid4()),
            "target": "core",
            "operation": "ping",
            "params": {},
        }
        completed = subprocess.run([str(ADAPTER)], input=json.dumps(payload).encode(), capture_output=True, timeout=5)
        self.assertNotEqual(completed.returncode, 0)

    def test_core_adapter_rejects_duplicate_keys(self):
        raw = b'{"version":1,"version":1,"request_id":"x","target":"core","operation":"ping","params":{}}'
        completed = subprocess.run([str(ADAPTER)], input=raw, capture_output=True, timeout=5)
        self.assertNotEqual(completed.returncode, 0)


if __name__ == "__main__":
    unittest.main()
