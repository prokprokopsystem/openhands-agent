"""Stop / SessionEnd hook: append new dialogue turns to a durable queue.

This hook is intentionally LLM-free and cheap (one directory scan, a few small
files). Its only job is to make sure that messages the agent never re-reads are
persisted somewhere outside the conversation, so a failed or skipped write can
be retried later.

It never blocks the agent: no stdout JSON, always exit 0, and any error is
logged and swallowed. Killing this hook loses nothing but the capture of that
moment — the transcript is still on disk and a later run picks it up from the
last recorded event index.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stage1_common as s1  # noqa: E402

HOOK = "capture"


def main() -> int:
    real_stdout = s1.protect_stdout()
    try:
        event = json.load(sys.stdin)
    except Exception as exc:
        s1.log(HOOK, f"bad stdin: {exc}")
        return 0

    try:
        cfg = s1.load_config()
    except Exception as exc:
        s1.log(HOOK, f"config unreadable: {exc}")
        return 0

    if not s1.enabled(cfg):
        return 0

    session_id = event.get("session_id") or ""
    if not session_id:
        s1.log(HOOK, "no session_id")
        return 0
    conv_hex = session_id.replace("-", "")

    # Project comes from the conversation's own workspace metadata (the hook
    # event carries it; the stored meta.json is the fallback). No project is
    # ever invented: an unknown or ephemeral workspace goes to the general bucket.
    ctx = s1.resolve_context(cfg, event.get("working_dir"), session_id)
    if not ctx.get("write"):
        return 0
    # scope=test is the previous limited mode: only projects listed in the config.
    if not s1.global_scope(cfg) and not ctx.get("explicit"):
        return 0
    project_id = ctx.get("project_id") or s1.general_id(cfg)

    events = s1.events_dir(cfg, session_id)
    if events is None:
        s1.log(HOOK, f"{conv_hex}: no events dir")
        return 0

    with s1.queue_lock(conv_hex) as locked:
        if not locked:
            s1.log(HOOK, f"{conv_hex}: queue busy, skip")
            return 0
        try:
            state = s1.read_state(conv_hex)
            known = {r.get("event_id") for r in s1.read_queue(conv_hex)}
            records, highest = s1.message_records(
                events,
                after_index=int(state.get("last_index", -1)),
                limit_chars=int(cfg.get("message_chars", 3000)),
            )
            fresh = [r for r in records if r.get("event_id") not in known]
            for record in fresh:
                record["conversation_id"] = session_id
                record["project_id"] = project_id
                if ctx.get("project_path"):
                    record["project_path"] = ctx["project_path"]
            s1.append_queue(conv_hex, fresh)
            state["last_index"] = highest
            state["last_capture_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            state["project_id"] = project_id
            state["project_path"] = ctx.get("project_path")
            state["captured_total"] = int(state.get("captured_total", 0)) + len(fresh)
            s1.write_state(conv_hex, state)
            if fresh:
                s1.log(
                    HOOK,
                    f"{conv_hex}: +{len(fresh)} turns (queued={len(known) + len(fresh)}) project={project_id}",
                )
        except Exception as exc:
            s1.log(HOOK, f"{conv_hex}: capture failed: {type(exc).__name__}: {exc}")
    real_stdout.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
