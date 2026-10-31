"""Live end-to-end driver for the stage-1 write path.

Creates real conversations in the isolated test project through the local
agent-server API, waits for them to finish and prints the evidence: the
canonical document, the queue, the write audit log and the hook events.

    venv/bin/python scripts/live_e2e.py say --label k1 --text "..."
    venv/bin/python scripts/live_e2e.py ask --label recall --text "..."
    venv/bin/python scripts/live_e2e.py show <conversation-id>

Credentials: the conversation is created from the encrypted agent settings of
the running server (``X-Expose-Secrets: encrypted``), so no plaintext key is
read or printed here.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

BASE = "http://127.0.0.1:18000"
PROJECT = "/projects/memory-pilot-test"
PLUGIN = "/home/openhands/.openhands/plugins/memory-pilot"
ROOT = Path("/projects/memory-pilot")


def api(path: str, *, method: str = "GET", body: Any = None, headers: dict | None = None) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", **(headers or {})},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        raw = response.read().decode()
    return json.loads(raw) if raw.strip() else {}


def encrypted_key(plaintext: str) -> str:
    """Same scheme the agent-server uses for at-rest secrets (OH_SECRET_KEY)."""
    import base64
    import hashlib
    import os

    from cryptography.fernet import Fernet

    secret = os.environ["OH_SECRET_KEY"].encode()
    cipher = Fernet(base64.b64encode(hashlib.sha256(secret).digest()))
    return cipher.encrypt(plaintext.encode()).decode()


def create_conversation(prompt: str, profile: str = "deepseek-chat", workspace: str = PROJECT) -> str:
    import sys as _sys

    _sys.path.insert(0, str(Path(__file__).resolve().parent))
    import stage1_common as s1

    settings = api("/api/settings", headers={"X-Expose-Secrets": "encrypted"})
    agent_settings = dict(settings["agent_settings"])
    agent_settings.pop("schema_version", None)
    agent_settings.pop("mcp_config", None)

    # The Canvas keeps provider keys in profiles only, so the API settings carry
    # no key. Take the local profile and send only its ciphertext.
    profile_data = json.loads(
        (Path.home() / ".openhands" / "profiles" / f"{profile}.json").read_text(encoding="utf-8")
    )
    key, _base_url, _model = s1.deepseek_credentials()
    llm = {k: v for k, v in profile_data.items() if k != "schema_version"}
    llm["api_key"] = encrypted_key(key)
    agent_settings["llm"] = llm
    agent_settings["tools"] = [
        {"name": "terminal", "params": {}},
        {"name": "file_editor", "params": {}},
        {"name": "task_tracker", "params": {}},
    ]
    payload = {
        "secrets_encrypted": True,
        "agent_settings": agent_settings,
        "plugins": [{"source": PLUGIN}],
        "workspace": {"kind": "LocalWorkspace", "working_dir": workspace},
        "confirmation_policy": {"kind": "NeverConfirm"},
        "max_iterations": 40,
        "stuck_detection": True,
        "autotitle": False,
        "worktree": False,
        "initial_message": {
            "role": "user",
            "content": [{"type": "text", "text": prompt}],
            "run": True,
        },
    }
    created = api("/api/conversations", method="POST", body=payload)
    return created["id"]


def wait(conversation_id: str, timeout: float = 300) -> str:
    deadline = time.time() + timeout
    status = "?"
    while time.time() < deadline:
        info = api(f"/api/conversations/{conversation_id}")
        status = info.get("execution_status") or "?"
        if status in ("finished", "idle", "error", "stuck", "stopped"):
            return status
        time.sleep(3)
    return f"timeout:{status}"


def events(conversation_id: str, limit: int = 50) -> list[dict]:
    data = api(f"/api/conversations/{conversation_id}/events/search?limit={limit}")
    return data.get("items") or data.get("events") or []


def report(conversation_id: str, status: str) -> None:
    print(f"conversation: {conversation_id}  status={status}")
    print(f"ui: http://localhost:8000/conversations/{conversation_id}")
    for event in events(conversation_id):
        kind = event.get("kind")
        if kind == "HookExecutionEvent":
            context = (event.get("additional_context") or "").strip()
            print(
                f"  hook {event.get('hook_event_type')}: success={event.get('success')} "
                f"exit={event.get('exit_code')} context={len(context)} chars"
            )
            if context:
                preview = " ".join(context.split())[:400]
                print(f"    {preview}")
        elif kind == "MessageEvent":
            role = (event.get("llm_message") or {}).get("role")
            text = " ".join(
                part.get("text", "")
                for part in ((event.get("llm_message") or {}).get("content") or [])
                if isinstance(part, dict)
            ).strip()
            if role == "assistant" and text:
                print(f"  assistant: {' '.join(text.split())[:500]}")
        elif kind == "ConversationErrorEvent":
            print(f"  ERROR {event.get('code')}: {event.get('detail')}")


def show_state() -> None:
    doc = Path(PROJECT) / "Решения.md"
    print("\n--- canonical document -------------------------------------------")
    print(doc.read_text(encoding="utf-8").strip() if doc.exists() else "(missing)")
    print(f"\n--- queue (scope={json.loads((ROOT / 'stage1' / 'config.json').read_text(encoding='utf-8')).get('scope')}) ---")
    queue = ROOT / "stage1" / "queue"
    for path in sorted(queue.glob("*.jsonl")):
        print(f"{path.name}: {len(path.read_text(encoding='utf-8').splitlines())} pending turns")
    if not list(queue.glob("*.jsonl")):
        print("(empty)")
    print("\n--- write audit ---------------------------------------------------")
    audit = ROOT / "stage1" / "writes.jsonl"
    if audit.exists():
        for line in audit.read_text(encoding="utf-8").splitlines()[-6:]:
            row = json.loads(line)
            print(
                f"{row.get('at')} {row.get('conversation', '')[:8]} {row.get('status')} "
                f"records={row.get('records')} facts={row.get('facts')} "
                f"doc_confirmed={row.get('doc_confirmed')}"
            )
    else:
        print("(no writes yet)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["say", "ask", "show", "state"])
    parser.add_argument("conversation_id", nargs="?")
    parser.add_argument("--label", default="")
    parser.add_argument("--text", default="")
    parser.add_argument("--workspace", default=PROJECT, help="LocalWorkspace path for the new chat")
    args = parser.parse_args()

    if args.command in ("say", "ask"):
        print(f"# {args.label or args.command}: {args.text[:120]}")
        conversation_id = create_conversation(args.text, workspace=args.workspace)
        status = wait(conversation_id)
        report(conversation_id, status)
        show_state()
        return 0 if status in ("finished", "idle") else 1
    if args.command == "show" and args.conversation_id:
        report(args.conversation_id, api(f"/api/conversations/{args.conversation_id}").get("execution_status", "?"))
        show_state()
        return 0
    show_state()
    return 0


if __name__ == "__main__":
    sys.exit(main())
