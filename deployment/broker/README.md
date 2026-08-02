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
