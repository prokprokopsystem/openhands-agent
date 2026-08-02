# Canvas Connector — stages 4D.4 and 4D.5

The Connector is the only approved base Canvas patch for broker transport. It uses a
derived image built from the pinned Canvas digest, a pinned OpenSSH package from a
fixed Debian snapshot, two exact read-only mounts, and one firewall path from
`10.89.0.2` to `10.89.0.1:22`.

The installer accepts only the exact completed 4D.3 state. Its preflight is
observational. The image is built and validated before Canvas is stopped. The apply
path creates a root-only copy of the pre-connector deployment and automatically
restores it if publication, restart, or validation fails.

```sh
sudo deployment/connector/install-canvas-connector.sh <full-commit-sha> --preflight-only
sudo deployment/connector/install-canvas-connector.sh <full-commit-sha>
sudo deployment/connector/validate-canvas-connector.sh <full-commit-sha>
sudo deployment/connector/accept-level-a-e2e.sh
```

## Rollback test and recovery

The exact pre-connector snapshot is recorded in
`/var/lib/openhands-broker/connector-state.json`. Rollback never deletes the snapshot,
the v2 or legacy keys, or the derived image:

```sh
sudo deployment/connector/rollback-canvas-connector.sh --confirm
```

Canonical recovery uses the connector commit recorded in project state:

1. Recover the protected base Canvas from the documented pre-connector baseline.
2. Preserve all server-side config, conversations, secrets, work-workspace, docs,
   Telegram, backup, and broker keys.
3. If the exact completed 4D.2/4D.3 broker state is absent, apply those approved
   transactional packages in order; otherwise validate it without reinstalling.
4. From an exact clean checkout of the canonical connector commit, run Connector
   preflight, install, validation, and `accept-level-a-e2e.sh` in that order.
5. Confirm service active, container healthy, Canvas HTTP, canonical manifest, and the
   Canvas UID 10001 to broker Level A response.

The recovery procedure is accepted only after an actual install → rollback → reinstall
cycle passes on mini-server. The older `de2244dd...` SHA remains the pre-connector
fallback and is not the normal recovery point after Connector freeze.
