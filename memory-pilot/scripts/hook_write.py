"""SessionStart / SessionEnd hook: one batched Mem0 write per pending chunk.

Why these two events:
  * SessionStart fires when a conversation is constructed, i.e. *before* the
    first user message of the new chat. Flushing there guarantees that facts
    from a chat that was closed or killed are written before the new chat asks
    its first question, so recall can see them immediately.
  * SessionEnd flushes the conversation that is closing.

The hook never asks the user anything and never blocks: it exits 0 on every
path, and on any exception the queue keeps the messages, so the next event
retries them. A batch is idempotent through ``batch_id`` written into the
record metadata: if a crash happens after ``add()`` but before the queue is
trimmed, the retry finds the batch in the store and skips the duplicate write.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stage1_common as s1  # noqa: E402

HOOK = "write"


def batch_messages(records: list[dict[str, Any]]) -> list[dict[str, str]]:
    """mem0 2.2.1 accepts list[dict] and drops bare strings inside a list."""
    return [
        {
            "role": "user" if record.get("role") == "user" else "assistant",
            "content": record.get("text", ""),
        }
        for record in records
    ]


def spec_for(cfg: dict[str, Any], record: dict[str, Any]) -> dict[str, Any]:
    """Resolve the write target from what capture recorded, not from a whitelist.

    The canonical document is re-checked here (not taken from the queue) so a
    document that appeared since capture is picked up, and a deleted one stops
    confirming decisions.
    """
    project_id = record.get("project_id") or s1.general_id(cfg)
    path_text = record.get("project_path")
    doc = None
    if path_text:
        try:
            path = Path(path_text).resolve()
        except Exception:
            path = None
        if path is not None and path.is_dir():
            spec = s1.explicit_spec(cfg, path)
            if spec is not None:
                project_id = spec.get("project_id") or project_id
            doc = (spec or {}).get("canonical_doc") or s1.find_doc(cfg, path)
    return {
        "project_id": project_id,
        "project_path": path_text,
        "canonical_doc": doc,
        "general": not path_text,
    }


def instructions_for(cfg: dict[str, Any], spec: dict[str, Any]) -> str:
    """Fill the extraction prompt for a project or for the general bucket."""
    template = cfg.get("custom_instructions") or ""
    if spec.get("project_path"):
        scope_line = f"проект «{spec['project_id']}» (каталог {spec['project_path']})"
        suffix = f" Указывай проект «{spec['project_id']}» в каждом факте."
    else:
        scope_line = "проект не определён — это общий разговор агента"
        suffix = " Не приписывай факты проекту, если он не назван в диалоге."
    return (
        template.replace("{{scope_line}}", scope_line)
        .replace("{{project_suffix}}", suffix)
        .replace("{{project_id}}", str(spec["project_id"]))
        .replace("{{date}}", time.strftime("%Y-%m-%d"))
    )


def memory_for(cfg: dict[str, Any], spec: dict[str, Any], cache: dict[str, Any]):
    """One Memory per project: custom_instructions needs the project name/date."""
    key = spec["project_id"]
    if key in cache:
        return cache[key]
    scoped = dict(cfg)
    scoped["custom_instructions"] = instructions_for(cfg, spec)
    cache[key] = s1.build_memory(scoped, with_llm=True)
    return cache[key]


def mark_doc(info: dict[str, Any], mem, results: list[dict[str, Any]]) -> dict[str, int]:
    stats = {"marked": 0, "confirmed": 0}
    for fact in results:
        memory_id = fact.get("id")
        if not memory_id or fact.get("event") not in ("ADD", "UPDATE"):
            continue
        verdict = s1.verify_against_doc(info, fact.get("memory") or "")
        metadata = {
            "doc_confirmed": verdict["doc_confirmed"],
            "doc_reason": verdict["doc_reason"],
            "doc_checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        if verdict.get("doc_ref"):
            metadata["doc_ref"] = verdict["doc_ref"]
        if verdict.get("doc_statuses"):
            metadata["doc_statuses"] = verdict["doc_statuses"]
        try:
            mem.update(memory_id, metadata=metadata)
            stats["marked"] += 1
            stats["confirmed"] += int(bool(verdict["doc_confirmed"]))
        except Exception as exc:
            s1.log(HOOK, f"{memory_id}: doc mark failed: {type(exc).__name__}: {exc}")
    return stats


def process_conversation(conv_hex: str, cfg: dict[str, Any], cache: dict[str, Any]) -> dict[str, Any]:
    outcome: dict[str, Any] = {"conversation": conv_hex, "status": "no_data", "records": 0, "facts": 0}
    with s1.queue_lock(conv_hex) as locked:
        if not locked:
            outcome["status"] = "busy"
            return outcome

        pending = s1.read_queue(conv_hex)
        if not pending:
            return outcome

        batch_size = int(cfg.get("max_messages_per_batch", 40))
        batch = pending[:batch_size]
        ids = ",".join(str(r.get("event_id")) for r in batch)
        batch_id = hashlib.sha256(f"{conv_hex}|{ids}".encode()).hexdigest()[:16]

        spec = spec_for(cfg, batch[0])

        agent_id = cfg.get("agent_id", "stage1-write")
        metadata = {
            "project_id": spec["project_id"],
            "scope": "project" if spec.get("project_path") else "general",
            "observation_date": (batch[0].get("ts") or "")[:10],
            "source": f"conversation:{batch[0].get('conversation_id')}",
            "source_conversation": batch[0].get("conversation_id"),
            "source_event_range": f"{batch[0].get('event_index')}..{batch[-1].get('event_index')}",
            "batch_id": batch_id,
            "stage": "stage1-auto",
        }
        if spec.get("project_path"):
            metadata["project_path"] = spec["project_path"]
        outcome.update(records=len(batch), batch_id=batch_id, project_id=spec["project_id"])

        try:
            mem = memory_for(cfg, spec, cache)
            already = mem.get_all(
                filters={"agent_id": agent_id, "batch_id": batch_id}, top_k=5
            ).get("results") or []
            if already:
                outcome["status"] = "already_written"
                written = already
            else:
                written = mem.add(
                    batch_messages(batch),
                    agent_id=agent_id,
                    metadata=metadata,
                    infer=True,
                )
                outcome["status"] = "written"
        except Exception as exc:
            outcome["status"] = "failed"
            outcome["error"] = f"{type(exc).__name__}: {exc}"
            s1.log(HOOK, f"{conv_hex}: batch {batch_id} failed, {len(batch)} turns kept: {outcome['error']}")
            state = s1.read_state(conv_hex)
            state["failures"] = int(state.get("failures", 0)) + 1
            state["last_failure"] = outcome["error"]
            state["last_failure_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            s1.write_state(conv_hex, state)
            return outcome

        facts = [
            f
            for f in (
                written.get("results", []) if isinstance(written, dict) else (written or [])
            )
            if f.get("event") in ("ADD", "UPDATE") and f.get("id")
        ]
        info = s1.doc_facts(spec.get("canonical_doc"))
        stats = mark_doc(info, mem, facts)
        outcome["facts"] = len(facts)
        outcome["doc_confirmed"] = stats["confirmed"]
        outcome["doc_checked"] = stats["marked"]

        state = s1.read_state(conv_hex)
        state.setdefault("batches", []).append(
            {
                "batch_id": batch_id,
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "records": len(batch),
                "facts": len(facts),
                "event_range": metadata["source_event_range"],
                "status": outcome["status"],
            }
        )
        state["written_total"] = int(state.get("written_total", 0)) + len(batch)
        s1.write_state(conv_hex, state)
        s1.rewrite_queue(conv_hex, pending[len(batch) :])
        s1.audit({**outcome, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        s1.log(HOOK, f"{conv_hex}: {outcome['status']} batch {batch_id}, {len(batch)} turns -> {len(facts)} facts")
    return outcome


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--conv", help="conversation hex id to flush")
    parser.add_argument("--sweep", action="store_true", help="flush every queued conversation")
    args = parser.parse_args()

    real_stdout = s1.protect_stdout()
    try:
        event: dict[str, Any] = {}
        if not args.conv and not args.sweep:
            try:
                event = json.load(sys.stdin)
            except Exception:
                event = {}
            session_id = (event.get("session_id") or "").replace("-", "")
            if session_id:
                args.conv = session_id
            else:
                args.sweep = True

        try:
            cfg = s1.load_config()
        except Exception as exc:
            s1.log(HOOK, f"config unreadable: {exc}")
            return 0
        if not s1.enabled(cfg):
            s1.log(HOOK, "disabled by config")
            return 0

        cache: dict[str, Any] = {}
        targets: list[str] = []
        if args.conv:
            targets.append(args.conv)
        if args.sweep:
            for path in sorted(s1.QUEUE_DIR.glob("*.jsonl")):
                name = path.stem
                if name not in targets:
                    targets.append(name)

        max_batches = int(cfg.get("max_batches_per_run", 3))
        store = cfg.get("store", s1.STAGE1 / "store")
        with s1.store_lock(store, wait=60) as got:
            if not got:
                s1.log(HOOK, "store busy for 60s, queue kept for the next event")
                real_stdout.close()
                return 0
            done = 0
            for conv_hex in targets:
                if done >= max_batches:
                    break
                try:
                    outcome = process_conversation(conv_hex, cfg, cache)
                except Exception as exc:
                    s1.log(HOOK, f"{conv_hex}: unexpected: {type(exc).__name__}: {exc}")
                    continue
                if outcome.get("status") in ("written", "already_written"):
                    done += 1
            s1.release_store(cache)
    except Exception as exc:
        s1.log(HOOK, f"fatal: {type(exc).__name__}: {exc}")
    finally:
        real_stdout.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
