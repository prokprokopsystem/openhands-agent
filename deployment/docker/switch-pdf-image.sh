#!/usr/bin/env bash
# Switch only OpenHands. Keep Compose bytes in memory for rollback, no .bak files.
set -euo pipefail
exec python3 - <<'PY'
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import time

COMPOSE = Path("/srv/openhands-agent/deployment/compose.yaml")
SERVICE = "openhands-agent.service"
OLD = "openhands-agent-canvas-ssh:1.6.1-restored"
NEW = "openhands-agent-canvas-ssh:1.6.1-restored-pdftools"
OLD_ID = "sha256:293042314e9e535e63c2c65f8df591e3eb545c5d781e402efb799b8a2a5d5a21"
NEW_ID = "sha256:40b7a43da65f14b5de79959b82544bec1d2cde4fd4535e9f0ed51e820778b188"

def log(message):
    print("[switch] " + message, flush=True)

def run(args, timeout=30):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # Compose stderr can contain interpolated credentials: do not print it.
        raise RuntimeError("Command failed: " + args[0] + " (exit " + str(result.returncode) + ")")
    return result.stdout

def inspect_image(reference):
    return json.loads(run(["docker", "image", "inspect", reference]))[0]

def inspect_container():
    try:
        return json.loads(run(["docker", "inspect", "openhands-agent"]))[0]
    except (RuntimeError, json.JSONDecodeError):
        return None

def config():
    return json.loads(run(["docker", "compose", "-f", str(COMPOSE), "config", "--format", "json"]))

def wait_healthy(image_id, previous_container=None, seconds=180):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        item = inspect_container()
        if (item and item.get("Image") == image_id
                and (previous_container is None or item.get("Id") != previous_container)
                and item.get("State", {}).get("Status") == "running"
                and item.get("State", {}).get("Health", {}).get("Status") == "healthy"):
            return item
        time.sleep(3)
    raise RuntimeError("Expected image did not become healthy in time")

def main():
    if os.geteuid() != 0:
        raise RuntimeError("Run through sudo")
    if COMPOSE.is_symlink() or not COMPOSE.is_file():
        raise RuntimeError("Unexpected Compose path")
    # Lock the existing inode; do not create lockfiles or replace file ownership.
    with COMPOSE.open("r+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original = handle.read()
        old_image = inspect_image(OLD)
        new_image = inspect_image(NEW)
        if old_image["Id"] != OLD_ID or new_image["Id"] != NEW_ID:
            raise RuntimeError("Image ID differs from the reviewed build")
        for field in ("Entrypoint", "Cmd", "User", "WorkingDir"):
            if old_image["Config"].get(field) != new_image["Config"].get(field):
                raise RuntimeError("Image runtime setting changed: " + field)
        before = config()
        selected = before["services"]["openhands"]["image"]
        current = inspect_container()
        if selected == NEW and current and current.get("Image") == NEW_ID:
            wait_healthy(NEW_ID)
            log("Already applied: expected PDF image is healthy. No changes.")
            return
        if selected != OLD or not current or current.get("Image") != OLD_ID:
            raise RuntimeError("Current Canvas differs from the expected starting state")
        pattern = rb"(?m)^([ \t]*image:[ \t]*)" + re.escape(OLD.encode()) + rb"([ \t]*\r?)$"
        updated, count = re.subn(pattern, lambda match: match[1] + NEW.encode() + match[2], original)
        if count != 1:
            raise RuntimeError("Expected exactly one image line")
        def write(data):
            handle.seek(0)
            handle.write(data)
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
        restart_attempted = False
        try:
            write(updated)
            after = config()
            after["services"]["openhands"]["image"] = OLD
            if after != before:
                raise RuntimeError("Compose changes extend beyond the OpenHands image")
            log("Restarting only OpenHands; Canvas will briefly disconnect.")
            restart_attempted = True
            run(["systemctl", "restart", SERVICE], timeout=240)
            item = wait_healthy(NEW_ID, previous_container=current["Id"])
        except BaseException:
            log("Restoring original Compose bytes from memory; no backup file created.")
            write(original)
            if restart_attempted:
                try:
                    run(["systemctl", "restart", SERVICE], timeout=240)
                    wait_healthy(OLD_ID)
                    log("Rollback verified: previous image is healthy.")
                except BaseException:
                    log("ROLLBACK NOT VERIFIED. Original Compose restored; inspect the OpenHands service.")
            raise
        log("SUCCESS: expected PDF image healthy, new container " + item["Id"][:12])
        log("ImageID=" + item["Image"])
        log("Next: verify PDF tools, SSH, GitHub and the model in the running Canvas.")

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        log("FAILED: " + str(error))
        raise SystemExit(1)
PY
