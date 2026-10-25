"""Failure-path checks; no Docker or systemd operations are executed."""
import copy
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "switch-pdf-image.sh"

def module():
    body = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    result = types.ModuleType("switch_pdf_test")
    exec(compile(body, str(SCRIPT), "exec"), result.__dict__)
    return result

class SwitchTests(unittest.TestCase):
    def scenario(self, failure=None):
        m = module()
        with tempfile.TemporaryDirectory() as folder:
            m.COMPOSE = Path(folder) / "compose.yaml"
            original = ("services:\n  openhands:\n    image: " + m.OLD + "\n").encode()
            m.COMPOSE.write_bytes(original)
            def image(reference):
                return {"Id": m.OLD_ID if reference == m.OLD else m.NEW_ID,
                        "Config": {"User": "openhands", "Cmd": ["serve"]}}
            current = {"Id": "old-container", "Image": m.OLD_ID}
            calls = []
            def config():
                new = m.NEW.encode() in m.COMPOSE.read_bytes()
                if new and failure == "validation":
                    raise RuntimeError("invalid compose")
                return {"services": {"openhands": {"image": m.NEW if new else m.OLD,
                       "ports": ["changed" if new and failure == "other-setting" else "8000"]}}}
            def run(args, timeout=30):
                self.assertEqual(args, ["systemctl", "restart", m.SERVICE])
                calls.append(args)
                if failure == "restart" and len(calls) == 1:
                    raise RuntimeError("restart failed")
                return ""
            def healthy(expected, previous_container=None, seconds=180):
                if failure == "health" and expected == m.NEW_ID:
                    raise RuntimeError("new image unhealthy")
                self.assertEqual(expected, m.NEW_ID if failure is None else m.OLD_ID)
                return {"Id": "new-container", "Image": expected}
            with patch.object(m.os, "geteuid", return_value=0), \
                 patch.object(m, "inspect_image", side_effect=image), \
                 patch.object(m, "inspect_container", return_value=copy.deepcopy(current)), \
                 patch.object(m, "config", side_effect=config), \
                 patch.object(m, "run", side_effect=run), \
                 patch.object(m, "wait_healthy", side_effect=healthy), \
                 patch.object(m, "log"):
                if failure:
                    with self.assertRaises(RuntimeError):
                        m.main()
                    self.assertEqual(m.COMPOSE.read_bytes(), original)
                else:
                    m.main()
                    self.assertEqual(m.COMPOSE.read_bytes(), original.replace(m.OLD.encode(), m.NEW.encode()))
            self.assertEqual([p.name for p in Path(folder).iterdir()], ["compose.yaml"])
            return len(calls)

    def test_success_without_backup_files(self):
        self.assertEqual(self.scenario(), 1)

    def test_invalid_compose_restores_without_restart(self):
        self.assertEqual(self.scenario("validation"), 0)

    def test_unrelated_compose_change_is_rejected(self):
        self.assertEqual(self.scenario("other-setting"), 0)

    def test_restart_failure_restores_previous_image(self):
        self.assertEqual(self.scenario("restart"), 2)

    def test_unhealthy_target_restores_previous_image(self):
        self.assertEqual(self.scenario("health"), 2)

    def test_old_healthy_container_cannot_satisfy_new_image_check(self):
        m = module()
        old = {"Id": "old", "Image": m.OLD_ID,
               "State": {"Status": "running", "Health": {"Status": "healthy"}}}
        with patch.object(m, "inspect_container", return_value=old), \
             patch.object(m.time, "monotonic", side_effect=[0, 0, 181]), \
             patch.object(m.time, "sleep"):
            with self.assertRaises(RuntimeError):
                m.wait_healthy(m.NEW_ID, previous_container="old")

if __name__ == "__main__":
    unittest.main()
