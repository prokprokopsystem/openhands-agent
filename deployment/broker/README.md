# Broker Core v2 — 4D.1

This directory contains the repository-only Broker Core v2 baseline. It does not
install or activate anything on a server.

The SSH forced-command launcher accepts no arguments and rejects a non-empty
`SSH_ORIGINAL_COMMAND`. One bounded UTF-8 JSON request is read from stdin and one
bounded JSON response is written to stdout. The registry is metadata-only; adapter
executables are selected exclusively by a fixed mapping in `broker_core.py`.
Registry files use the strict JSON-compatible subset of YAML so duplicate keys and
unknown fields can be rejected deterministically without an extra runtime parser.

Only the credential-free `core.ping` and `core.capabilities` operations are present.
Level B is disabled until its 4D.6 reversible-write contract, and Level C is disabled
until its separate 4D.8 creator/consumer implementation.

Run the tests from the repository root:

```sh
python3 -m unittest discover -s deployment/broker/tests -v
```

## 4D.2 frozen-v1 migration

`install-broker-v2.sh` is intentionally not a generic installer. It accepts only the
exact frozen v1 broker currently identified on mini-server. Before any replacement it
verifies the legacy wrapper, registry, sudoers, sshd policy, authorized key, pinned host
key, account layout, and preserved client keypair. Any mismatch stops before mutation.

The migration creates a root-only snapshot under
`/var/lib/openhands-broker/migrations/`, removes the legacy sudo grants, installs the
root-owned v2 core/registry, creates isolated non-login adapter identities and empty
credential boundaries, installs the fixed forced command, and validates the installed
process path. It never installs Canvas connector files and never modifies the preserved
client keypair.

Run only from a clean checkout at the separately approved commit:

```sh
sudo deployment/broker/install-broker-v2.sh <full-commit-sha> --preflight-only
sudo deployment/broker/install-broker-v2.sh <full-commit-sha>
sudo deployment/broker/validate-install-v2.sh <full-commit-sha>
```

If the migration fails after replacement begins, it automatically restores the exact
v1 snapshot. Manual rollback requires the exact snapshot path printed by the installer:

```sh
sudo deployment/broker/rollback-broker-v1.sh \
  /var/lib/openhands-broker/migrations/<exact-snapshot> --confirm
```

`uninstall-broker-v2.sh --confirm` removes only v2 broker identities and artifacts. It
preserves migration snapshots and `/srv/openhands-agent/secrets/broker-mini-server.key*`.
