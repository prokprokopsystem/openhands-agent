"""Tests for bounded recovery patches; no Docker/host mutations."""
import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('restore', Path(__file__).parents[1] / 'restore-canvas-ssh.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class RecoveryTests(unittest.TestCase):
    def test_compose_patch_and_drift(self):
        text = 'services:\n  openhands:\n    image: ' + m.BASE_IMAGE + '\n    volumes:\n      - /srv/openhands-agent/docs:/docs:ro\n'
        new = m.patch_compose(text)
        self.assertIn('    pull_policy: never', new)
        self.assertEqual(new.count('/run/openhands-ssh-key:ro'), 1)
        with self.assertRaises(RuntimeError):
            m.patch_compose(new)
        with self.assertRaises(RuntimeError):
            m.patch_compose(text.replace(m.BASE_IMAGE, 'other'))

    def test_firewall_scope_and_order(self):
        anchor = 'iptables -A "${INPUT_CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
        text = 'iptables -A "${EGRESS_CHAIN}" -d 10.0.0.0/8 -j DROP\n' + anchor + 'iptables -A "${INPUT_CHAIN}" -j DROP\n'
        new = m.patch_firewall(text)
        self.assertIn('-s 10.89.0.2/32 -d 10.89.0.1/32 -p tcp --dport 22 -j ACCEPT', new)
        self.assertLess(new.index('--dport 22'), new.index('iptables -A "${INPUT_CHAIN}" -j DROP'))
        self.assertEqual(new.splitlines()[0], text.splitlines()[0])
        with self.assertRaises(RuntimeError):
            m.patch_firewall(new)

    def test_host_identity(self):
        m.validate_identity('mini-server\nuid=1000(igor) gid=1000(igor)\n')
        with self.assertRaises(RuntimeError):
            m.validate_identity('container\nuid=10001(openhands)\n')

if __name__ == '__main__':
    unittest.main()
