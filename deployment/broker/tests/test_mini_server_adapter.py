import json
import os
import subprocess
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "adapters" / "mini-server-adapter"


def payload(operation="filesystem_usage", params=None, target="mini-server"):
    return json.dumps(
        {
            "version": 1,
            "request_id": str(uuid.uuid4()),
            "target": target,
            "operation": operation,
            "params": params if params is not None else {"path": "/"},
        },
        separators=(",", ":"),
    ).encode()


class MiniServerAdapterTests(unittest.TestCase):
    def run_adapter(self, raw):
        return subprocess.run([str(ADAPTER)], input=raw, capture_output=True, timeout=10)

    def test_filesystem_usage_is_read_only_and_bounded(self):
        completed = self.run_adapter(payload())
        response = json.loads(completed.stdout)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["result"]["path"], "/")
        self.assertGreater(response["result"]["total_bytes"], 0)
        self.assertLessEqual(len(completed.stdout), 16 * 1024 + 1)
        self.assertEqual(response["verify"]["status"], "not_applicable")
        self.assertEqual(response["rollback"]["status"], "not_applicable")

    def test_unlisted_path_is_rejected(self):
        completed = self.run_adapter(payload(params={"path": "/etc"}))
        self.assertNotEqual(completed.returncode, 0)

    def test_extra_parameter_is_rejected(self):
        completed = self.run_adapter(payload(params={"path": "/", "command": "id"}))
        self.assertNotEqual(completed.returncode, 0)

    def test_target_mismatch_is_rejected(self):
        completed = self.run_adapter(payload(target="vps"))
        self.assertNotEqual(completed.returncode, 0)

    def test_duplicate_json_key_is_rejected(self):
        completed = self.run_adapter(b'{"version":1,"version":1}')
        self.assertNotEqual(completed.returncode, 0)

    def test_source_has_no_shell_execution(self):
        source = ADAPTER.read_text(encoding="utf-8")
        self.assertNotIn("shell=True", source)
        self.assertNotIn("os.system", source)
        self.assertNotIn("bash -c", source)
        self.assertNotIn("eval(", source)


class MiniServerDispatchTests(unittest.TestCase):
    def test_dispatch_is_fixed_to_adapter_identity(self):
        source = (ROOT / "broker_core.py").read_text(encoding="utf-8")
        self.assertIn('"mini-server": (', source)
        self.assertIn('"openhands-adapter-mini-server"', source)
        self.assertIn('root / "adapters" / "mini-server-adapter"', source)
        self.assertNotIn("tool.operation]", source)
        self.assertNotIn("tool.target]", source)

    def test_registry_exposes_only_level_a(self):
        registry = json.loads((ROOT / "tools.d" / "mini-server.yaml").read_text(encoding="utf-8"))
        self.assertEqual({tool["risk"] for tool in registry["tools"]}, {"A"})
        self.assertEqual(
            {tool["name"] for tool in registry["tools"]},
            {"mini_server.health", "mini_server.filesystem_usage"},
        )


if __name__ == "__main__":
    unittest.main()
