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
key, account layout, the frozen empty `secrets/` directory, and legacy public-key
authorization. The legacy private key is preserved as opaque data because its frozen
`0640` mode is intentionally not changed. Any mismatch stops before mutation.

`--preflight-only` performs no lock-file, temporary-file, audit, key, or system-policy
write. The apply path creates a separate v2 ED25519 client key under
`/srv/openhands-agent/secrets/openhands-broker-v2/`; its private key is owned by Canvas
UID/GID `10001:10001` with mode `0600`. Existing legacy key files are never overwritten,
renamed, chmodded, or deleted.

Private/public v2 key correspondence is checked only by SHA256 fingerprints:
`ssh-keygen -y -f PRIVATE | ssh-keygen -lf - -E sha256` is compared with
`ssh-keygen -lf PUBLIC -E sha256`. Raw public-key strings and comments are not used as
the equality contract.

The migration creates a root-only snapshot under
`/var/lib/openhands-broker/migrations/`, removes the legacy sudo grants, installs the
root-owned v2 core/registry, creates isolated non-login adapter identities and empty
credential boundaries, installs the fixed forced command, and validates the installed
process path. The snapshot records a hash manifest for the fixed base Canvas files and
install, validation, rollback, and uninstall fail if those files change. It never
installs Canvas connector files.

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
preserves migration snapshots, the frozen legacy keypair, and the separate v2 keypair.
