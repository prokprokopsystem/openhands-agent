#!/usr/bin/python3
"""Fixed bounded Canvas-to-broker SSH transport client."""

from __future__ import annotations

import json
import os
import selectors
import stat
import subprocess
import sys
import time


MAX_REQUEST_BYTES = 16 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
TIMEOUT_SECONDS = 15
KEY_PATH = "/run/openhands-broker/client/id_ed25519"
TRUST_PATH = "/run/openhands-broker/client/client_known_hosts"
SAFE_ENV = {
    "PATH": "/usr/bin:/bin",
    "HOME": "/nonexistent",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
}
SSH_COMMAND = (
    "/usr/bin/ssh",
    "-F", "/dev/null",
    "-T",
    "-o", "BatchMode=yes",
    "-o", "IdentitiesOnly=yes",
    "-o", "IdentityAgent=none",
    "-o", "StrictHostKeyChecking=yes",
    "-o", f"UserKnownHostsFile={TRUST_PATH}",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "PasswordAuthentication=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "PubkeyAuthentication=yes",
    "-o", "HostKeyAlgorithms=ssh-ed25519",
    "-o", "PubkeyAcceptedAlgorithms=ssh-ed25519",
    "-o", "ClearAllForwardings=yes",
    "-o", "PermitLocalCommand=no",
    "-o", "RequestTTY=no",
    "-o", "ConnectTimeout=5",
    "-o", "ConnectionAttempts=1",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=1",
    "-o", "LogLevel=ERROR",
    "-i", KEY_PATH,
    "openhands-broker@10.89.0.1",
)


class TransportError(RuntimeError):
    pass


def fixed_error(code: str) -> bytes:
    return json.dumps(
        {
            "version": 1,
            "request_id": None,
            "status": "error",
            "error": {"code": code, "message": "broker connector transport failed"},
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"


def validate_file(path: str) -> None:
    metadata = os.lstat(path)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_gid != 10001:
        raise TransportError("connector file metadata mismatch")
    if stat.S_IMODE(metadata.st_mode) != 0o640 or not os.access(path, os.R_OK) or os.access(path, os.W_OK):
        raise TransportError("connector file access mismatch")


def communicate_bounded(process: subprocess.Popen[bytes], payload: bytes) -> bytes:
    assert process.stdin is not None and process.stdout is not None
    try:
        process.stdin.write(payload)
        process.stdin.close()
    except BrokenPipeError:
        pass
    deadline = time.monotonic() + TIMEOUT_SECONDS
    output = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                process.wait()
                raise TransportError("transport timeout")
            ready = selector.select(remaining)
            if not ready:
                process.kill()
                process.wait()
                raise TransportError("transport timeout")
            chunk = os.read(process.stdout.fileno(), min(4096, MAX_RESPONSE_BYTES + 1 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > MAX_RESPONSE_BYTES:
                process.kill()
                process.wait()
                raise TransportError("transport response too large")
        try:
            process.wait(timeout=max(deadline - time.monotonic(), 0.001))
        except subprocess.TimeoutExpired as exc:
            process.kill()
            process.wait()
            raise TransportError("transport timeout") from exc
        if not output:
            raise TransportError("transport returned no response")
        return bytes(output)
    finally:
        selector.close()
        process.stdout.close()


def main() -> int:
    if len(sys.argv) != 1:
        sys.stdout.buffer.write(fixed_error("arguments_forbidden"))
        return 2
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if not payload or len(payload) > MAX_REQUEST_BYTES:
        sys.stdout.buffer.write(fixed_error("invalid_request_size"))
        return 2
    try:
        validate_file(KEY_PATH)
        validate_file(TRUST_PATH)
        process = subprocess.Popen(
            list(SSH_COMMAND),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=SAFE_ENV,
        )
        response = communicate_bounded(process, payload)
    except (OSError, TransportError):
        sys.stdout.buffer.write(fixed_error("connector_transport_failed"))
        return 2
    sys.stdout.buffer.write(response)
    sys.stdout.buffer.flush()
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
