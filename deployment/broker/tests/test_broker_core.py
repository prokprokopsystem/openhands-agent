import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from broker_core import (  # noqa: E402
    AdapterRunner,
    BrokerApp,
    BrokerError,
    MAX_RESPONSE_BYTES,
    Registry,
    Tool,
    compact_json,
    decode_json_object,
)


class MemoryAudit:
    def __init__(self):
        self.events = []

    def write(self, event):
        self.events.append(event)


class FakeRunner:
    def __init__(self, result=None, error=None):
        self.result = result or {
            "status": "ok",
            "result": {"pong": True},
            "result_code": "ok",
            "verify": {"status": "not_applicable"},
            "rollback": {"status": "not_applicable"},
        }
        self.error = error
        self.calls = []

    def execute(self, tool, request):
        self.calls.append((tool, request))
        if self.error:
            raise self.error
        return self.result


def request(tool="core.ping", params=None, approval_id="absent"):
    value = {
        "version": 1,
        "request_id": str(uuid.uuid4()),
        "tool": tool,
        "params": params or {},
    }
    if approval_id != "absent":
        value["approval_id"] = approval_id
    return json.dumps(value, separators=(",", ":")).encode()


class BrokerCoreTests(unittest.TestCase):
    def setUp(self):
        self.registry = Registry.load(ROOT / "tools.d")
        self.audit = MemoryAudit()
        self.runner = FakeRunner()
        self.app = BrokerApp(self.registry, self.audit, self.runner)

    def assert_code(self, expected, raw):
        with self.assertRaises(BrokerError) as caught:
            self.app.handle(raw)
        self.assertEqual(caught.exception.code, expected)

    def test_ping_canonicalizes_and_audits(self):
        response = self.app.handle(request())
        self.assertEqual(response["status"], "ok")
        self.assertEqual([e["event"] for e in self.audit.events], ["STARTED", "SUCCEEDED"])
        descriptor = self.audit.events[0]["descriptor"]
        self.assertEqual(descriptor["canonical_params"], {})
        self.assertEqual(self.runner.calls[0][1]["operation"], "ping")
        final = self.audit.events[-1]
        self.assertEqual(final["risk"], "A")
        self.assertEqual(final["result_code"], "ok")
        self.assertEqual(final["verify_status"], "not_applicable")
        self.assertEqual(final["rollback_status"], "not_applicable")
        self.assertIsInstance(final["duration_ms"], int)

    def test_invalid_utf8_rejected(self):
        self.assert_code("invalid_request", b"\xff")

    def test_duplicate_json_key_rejected(self):
        self.assert_code("invalid_request", b'{"version":1,"version":1}')

    def test_boolean_version_rejected(self):
        value = json.loads(request())
        value["version"] = True
        self.assert_code("unsupported_version", json.dumps(value).encode())

    def test_non_finite_json_rejected(self):
        raw = request().replace(b'"params":{}', b'"params":{"value":NaN}')
        self.assert_code("invalid_request", raw)

    def test_second_json_object_rejected(self):
        self.assert_code("invalid_request", b"{}{}")

    def test_oversized_request_rejected(self):
        self.assert_code("request_too_large", b"{" + b" " * (16 * 1024))

    def test_unknown_top_level_field_rejected(self):
        value = json.loads(request())
        value["extra"] = True
        self.assert_code("invalid_request", json.dumps(value).encode())

    def test_noncanonical_uuid_rejected(self):
        value = json.loads(request())
        value["request_id"] = value["request_id"].upper()
        self.assert_code("invalid_request_id", json.dumps(value).encode())

    def test_unknown_tool_rejected(self):
        self.assert_code("unknown_tool", request(tool="missing.tool"))

    def test_unknown_parameter_rejected(self):
        self.assert_code("invalid_params", request(params={"command": "id"}))

    def test_approval_for_level_a_rejected(self):
        self.assert_code("unexpected_approval", request(approval_id="anything"))

    def test_level_c_disabled(self):
        tool = Tool("danger.test", "core", "core", "ping", "C", {}, 5, 8192)
        app = BrokerApp(Registry({tool.name: tool}), self.audit, self.runner)
        with self.assertRaises(BrokerError) as caught:
            app.handle(request(tool=tool.name, approval_id="approval"))
        self.assertEqual(caught.exception.code, "level_c_disabled")
        self.assertEqual(self.audit.events, [])

    def test_level_b_disabled_until_4d6(self):
        tool = Tool("write.test", "core", "core", "ping", "B", {}, 5, 8192)
        app = BrokerApp(Registry({tool.name: tool}), self.audit, self.runner)
        with self.assertRaises(BrokerError) as caught:
            app.handle(request(tool=tool.name))
        self.assertEqual(caught.exception.code, "level_b_disabled")
        self.assertEqual(self.audit.events, [])

    def test_audit_failure_prevents_adapter_execution(self):
        class FailedAudit:
            def write(self, event):
                raise BrokerError("audit_unavailable", "unavailable", status="error")

        runner = FakeRunner()
        app = BrokerApp(self.registry, FailedAudit(), runner)
        with self.assertRaises(BrokerError) as caught:
            app.handle(request())
        self.assertEqual(caught.exception.code, "audit_unavailable")
        self.assertEqual(runner.calls, [])

    def test_adapter_failure_gets_terminal_audit(self):
        app = BrokerApp(self.registry, self.audit, FakeRunner(error=BrokerError("adapter_failed", "failed", status="error")))
        with self.assertRaises(BrokerError):
            app.handle(request())
        self.assertEqual([e["event"] for e in self.audit.events], ["STARTED", "FAILED"])


class RegistryTests(unittest.TestCase):
    def write_registry(self, document):
        temporary = tempfile.TemporaryDirectory()
        path = Path(temporary.name) / "test.yaml"
        path.write_text(json.dumps(document), encoding="utf-8")
        return temporary, Path(temporary.name)

    def base_tool(self):
        return {
            "name": "core.ping",
            "target": "core",
            "adapter": "core",
            "operation": "ping",
            "risk": "A",
            "params": {},
            "timeout_seconds": 5,
            "max_output_bytes": 8192,
        }

    def test_registry_rejects_shell_execution_field(self):
        tool = self.base_tool()
        tool["execute"] = "bash -c id"
        temporary, directory = self.write_registry({"version": 1, "tools": [tool]})
        self.addCleanup(temporary.cleanup)
        with self.assertRaises(BrokerError):
            Registry.load(directory)

    def test_registry_rejects_secret_field(self):
        tool = self.base_tool()
        tool["secrets"] = ["TOKEN"]
        temporary, directory = self.write_registry({"version": 1, "tools": [tool]})
        self.addCleanup(temporary.cleanup)
        with self.assertRaises(BrokerError):
            Registry.load(directory)

    def test_registry_rejects_duplicate_tools(self):
        tool = self.base_tool()
        temporary, directory = self.write_registry({"version": 1, "tools": [tool, tool]})
        self.addCleanup(temporary.cleanup)
        with self.assertRaises(BrokerError):
            Registry.load(directory)

    def test_registry_rejects_mismatched_constraint(self):
        tool = self.base_tool()
        tool["params"] = {"count": {"type": "integer", "max_length": 5}}
        temporary, directory = self.write_registry({"version": 1, "tools": [tool]})
        self.addCleanup(temporary.cleanup)
        with self.assertRaises(BrokerError):
            Registry.load(directory)

    def test_registry_rejects_boolean_version(self):
        temporary, directory = self.write_registry({"version": True, "tools": [self.base_tool()]})
        self.addCleanup(temporary.cleanup)
        with self.assertRaises(BrokerError):
            Registry.load(directory)


class DecoderTests(unittest.TestCase):
    def test_non_object_rejected(self):
        with self.assertRaises(BrokerError):
            decode_json_object(b"[]", 100, "request")

    def test_serializer_rejects_non_finite_number(self):
        with self.assertRaises(ValueError):
            compact_json({"result": float("nan")})

    def test_global_response_limit_fails_closed(self):
        code = (
            "from broker_core import emit; "
            "emit({'version':1,'request_id':None,'status':'ok','result':'x'*70000})"
        )
        env = dict(os.environ)
        env["PYTHONPATH"] = str(ROOT)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        completed = __import__("subprocess").run(
            [sys.executable, "-c", code], capture_output=True, env=env, timeout=5
        )
        response = json.loads(completed.stdout)
        self.assertLessEqual(len(completed.stdout), MAX_RESPONSE_BYTES + 1)
        self.assertEqual(response["error"]["code"], "response_too_large")


class AdapterBoundaryTests(unittest.TestCase):
    def test_output_limit_is_enforced_while_reading(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "oversized-adapter"
            executable.write_text(
                "#!/usr/bin/python3\nimport sys\nsys.stdin.buffer.read()\nsys.stdout.write('x' * 300)\n",
                encoding="utf-8",
            )
            os.chmod(executable, 0o755)
            runner = AdapterRunner(ROOT)
            runner.executables["core"] = executable
            tool = Tool("core.ping", "core", "core", "ping", "A", {}, 5, 256)
            with self.assertRaises(BrokerError) as caught:
                runner.execute(tool, {"version": 1})
            self.assertEqual(caught.exception.code, "adapter_output_too_large")

    def test_unknown_adapter_fails_closed(self):
        runner = AdapterRunner(ROOT)
        tool = Tool("missing.ping", "missing", "missing", "ping", "A", {}, 5, 8192)
        with self.assertRaises(BrokerError) as caught:
            runner.execute(tool, {"version": 1})
        self.assertEqual(caught.exception.code, "adapter_unavailable")

    def test_adapter_timeout_is_enforced(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "slow-adapter"
            executable.write_text(
                "#!/usr/bin/python3\nimport sys,time\nsys.stdin.buffer.read()\ntime.sleep(3)\n",
                encoding="utf-8",
            )
            os.chmod(executable, 0o755)
            runner = AdapterRunner(ROOT)
            runner.executables["core"] = executable
            tool = Tool("core.ping", "core", "core", "ping", "A", {}, 1, 256)
            with self.assertRaises(BrokerError) as caught:
                runner.execute(tool, {"version": 1})
            self.assertEqual(caught.exception.code, "adapter_timeout")


if __name__ == "__main__":
    unittest.main()
