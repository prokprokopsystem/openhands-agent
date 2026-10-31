"""M3 test #2B — minimal actualisation: superseded_by on the cancelled decision.

Same two rounds as test #2 in a fresh isolated collection, then ONE stock API call
per cancelled record: `update(memory_id, metadata={"superseded_by": ..., "status": ...})`
plus `expiration_date`, so that default search hides it and history search keeps it.

The hard part is mapping the model's `linked_memory_ids` ("0","1", ...) to real Mem0
UUIDs: mem0 builds that mapping (`uuid_mapping`) and never uses it. This harness
reconstructs it from evidence and proves the correspondence before writing anything:

  proof 1 — the extraction prompt the model actually received lists
            [{"id": "0", "text": "..."}] for existing memories, so the text is what
            the model saw under that index;
  proof 2 — each such text matches exactly one stored record's payload `data`;
  proof 3 — the vector-store search result order captured during add() equals the
            order in the prompt.

Usage:
  venv/bin/python scripts/m3t2b_actualize_test.py --reset
  venv/bin/python scripts/m3t2b_actualize_test.py --check-only   # new process
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

ROOT = Path("/projects/memory-pilot")
TEST_STORE = ROOT / "test-m3t2b" / "store"
TEST_COLLECTION = "m3t2b_memories"
TEST_AGENT_ID = "m3t2b-agent"
PROJECT = "TEST-VALVE-02"

from m3t1_infer_test import EMBED_DIMS, EMBED_MODEL, MODELS, deepseek_credentials  # noqa: E402
from m3t1b_infer_test import CUSTOM_INSTRUCTIONS  # noqa: E402
from m3t2_supersede_test import ROUND_A, ROUND_B  # noqa: E402

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS))

from mem0 import Memory  # noqa: E402
from mem0.configs.base import MemoryConfig  # noqa: E402
from mem0.embeddings.configs import EmbedderConfig  # noqa: E402
from mem0.llms.configs import LlmConfig  # noqa: E402
from mem0.vector_stores.configs import VectorStoreConfig  # noqa: E402

QUERY_NOW = "Как сейчас управляется V1?"
QUERY_WHY = "Почему отказались от K2?"


class Meter:
    """Counts LLM calls and keeps the full prompts and responses."""

    def __init__(self, mem: Memory):
        self.calls: list[dict] = []
        self.prompts: list[str] = []
        self.raw: list[str] = []
        create = mem.llm.client.chat.completions.create

        def counted(**kwargs):
            started = time.monotonic()
            response = create(**kwargs)
            usage = getattr(response, "usage", None)
            user_prompt = next(
                (m["content"] for m in kwargs.get("messages", []) if m.get("role") == "user"), ""
            )
            self.prompts.append(user_prompt)
            self.calls.append(
                {
                    "prompt_tokens": getattr(usage, "prompt_tokens", None),
                    "completion_tokens": getattr(usage, "completion_tokens", None),
                    "total_tokens": getattr(usage, "total_tokens", None),
                    "seconds": round(time.monotonic() - started, 2),
                    "user_prompt_chars": len(user_prompt),
                }
            )
            content = response.choices[0].message.content
            if isinstance(content, str):
                self.raw.append(content)
            return response

        mem.llm.client.chat.completions.create = counted

    def summary(self) -> dict:
        def total(field: str) -> int:
            return sum(c[field] or 0 for c in self.calls)

        return {
            "llm_calls": len(self.calls),
            "prompt_tokens": total("prompt_tokens"),
            "completion_tokens": total("completion_tokens"),
            "total_tokens": total("total_tokens"),
            "llm_seconds": round(sum(c["seconds"] for c in self.calls), 2),
        }


class Capture:
    """Records the vector-store search results the add() pipeline actually used."""

    def __init__(self, mem: Memory):
        self.active = False
        self.existing: list = []
        original = mem.vector_store.search

        def wrapped(**kwargs):
            results = original(**kwargs)
            if self.active:
                self.existing = results
            return results

        mem.vector_store.search = wrapped


def build_memory() -> Memory:
    key, base_url, model = deepseek_credentials()
    assert TEST_COLLECTION not in ("m2_memories", "m3t1_memories", "m3t1b_memories", "m3t2_memories")
    assert TEST_STORE != ROOT / "store"
    return Memory(
        config=MemoryConfig(
            vector_store=VectorStoreConfig(
                provider="qdrant",
                config={
                    "path": str(TEST_STORE / "qdrant_db"),
                    "collection_name": TEST_COLLECTION,
                    "embedding_model_dims": EMBED_DIMS,
                    "on_disk": True,
                },
            ),
            embedder=EmbedderConfig(
                provider="fastembed",
                config={"model": EMBED_MODEL, "embedding_dims": EMBED_DIMS},
            ),
            llm=LlmConfig(
                provider="deepseek",
                config={
                    "api_key": key,
                    "model": model,
                    "deepseek_base_url": base_url,
                    "temperature": 0.1,
                    "max_tokens": 2000,
                },
            ),
            history_db_path=str(TEST_STORE / "history.db"),
            custom_instructions=CUSTOM_INSTRUCTIONS,
        )
    )


def round_metadata(name: str) -> dict:
    return {
        "project_id": PROJECT,
        "source": f"test-m3t2b-{name}",
        "conversation_id": f"{PROJECT}/m3t2b",
        "observation_date": "2026-10-31",
        "round": name,
    }


def all_records(mem: Memory, show_expired: bool = True) -> list[dict]:
    items = mem.get_all(filters={"agent_id": TEST_AGENT_ID}, top_k=100, show_expired=show_expired)
    return items.get("results", items) if isinstance(items, dict) else items


def show(mem: Memory, label: str, show_expired: bool = True) -> list[dict]:
    rows = all_records(mem, show_expired)
    print(f"\n## {label}: {len(rows)} record(s)")
    for number, row in enumerate(rows, start=1):
        meta = row.get("metadata") or {}
        marker = ""
        if meta.get("superseded_by"):
            marker = f"  <<< SUPERSEDED by {meta['superseded_by'][:8]}"
        print(f"{number}. [{row.get('id')[:8]}] {row.get('memory')}{marker}")
        print(f"   status={meta.get('status')} round={meta.get('round')} expires={meta.get('expiration_date')}")
    return rows


def print_hits(label: str, hits: list[dict]) -> None:
    print(f"  {label}: {len(hits)} hit(s)")
    for hit in hits:
        print(f"    [{hit.get('score'):.3f}] [{str(hit.get('id'))[:8]}] {hit.get('memory')[:100]}")


def parse_prompt_existing(prompt: str) -> list[dict]:
    """Extract the 'Existing Memories' section the model was given."""
    marker = "## Existing Memories"
    if marker not in prompt:
        return []
    section = prompt.split(marker, 1)[1]
    for stop in ("## New Messages", "## Last k Messages", "## Custom Instructions"):
        if stop in section:
            section = section.split(stop, 1)[0]
    start, end = section.find("["), section.rfind("]")
    if start == -1 or end == -1:
        return []
    try:
        return json.loads(section[start : end + 1])
    except json.JSONDecodeError:
        return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("--check-only", action="store_true", help="fresh process, read-only")
    parser.add_argument(
        "--probe-status",
        action="store_true",
        help="tag surviving records with status=active, then re-test the status filters",
    )
    args = parser.parse_args()

    checks: list[tuple[str, bool, str]] = []

    if args.probe_status:
        mem = build_memory()
        rows = all_records(mem)
        print("## Before tagging")
        for row in rows:
            meta = row.get("metadata") or {}
            print(f"  [{row['id'][:8]}] status={meta.get('status')} :: {row['memory'][:60]}")

        untagged = [r["id"] for r in rows if not (r.get("metadata") or {}).get("status")]
        print(f"\n## Tagging {len(untagged)} untagged record(s) with status=active")
        for uuid in untagged:
            mem.update(uuid, metadata={"status": "active"})

        print("\n## Filter {'status': {'ne': 'superseded'}} (default search)")
        ne_hits = mem.search(
            QUERY_NOW, filters={"agent_id": TEST_AGENT_ID, "status": {"ne": "superseded"}}, top_k=10
        )["results"]
        print_hits(QUERY_NOW, ne_hits)

        print("\n## Filter {'status': 'active'} (default search)")
        active_hits = mem.search(
            QUERY_NOW, filters={"agent_id": TEST_AGENT_ID, "status": "active"}, top_k=10
        )["results"]
        print_hits(QUERY_NOW, active_hits)

        print("\n## Filter {'status': 'superseded'} + show_expired=True")
        sup_hits = mem.search(
            QUERY_NOW,
            filters={"agent_id": TEST_AGENT_ID, "status": "superseded"},
            top_k=10,
            show_expired=True,
        )["results"]
        print_hits(QUERY_NOW, sup_hits)

        print("\n## Plain search (no caller filters) still hides expired")
        plain_hits = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID}, top_k=10)["results"]
        print_hits(QUERY_NOW, plain_hits)

        print("\n## Residual K2 assertions still active")
        for row in all_records(mem):
            meta = row.get("metadata") or {}
            if meta.get("status") == "active" and "K2" in row["memory"]:
                print(f"  [{row['id'][:8]}] {row['memory'][:110]}")
        return 0

    if args.check_only:
        mem = build_memory()
        rows = show(mem, "FRESH PROCESS — all records (show_expired=True)")
        print("\n## FRESH PROCESS — default search (no extra filters)")
        default_hits = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID}, top_k=5)["results"]
        print_hits(QUERY_NOW, default_hits)
        print("\n## FRESH PROCESS — history search (show_expired=True)")
        hist_hits = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID}, top_k=5, show_expired=True)[
            "results"
        ]
        print_hits(QUERY_NOW, hist_hits)
        superseded_ids = [r["id"] for r in rows if (r.get("metadata") or {}).get("superseded_by")]
        stale_in_default = [h for h in default_hits if h["id"] in superseded_ids]
        stale_in_history = [h for h in hist_hits if h["id"] in superseded_ids]
        print(f"\nsuperseded ids: {[i[:8] for i in superseded_ids]}")
        print(f"stale present in default search: {len(stale_in_default)}")
        print(f"stale present in history search: {len(stale_in_history)}")
        ok = len(rows) == 5 and not stale_in_default and len(stale_in_history) >= 1
        print(f"\nFRESH PROCESS VERDICT: {'PASS' if ok else 'FAIL'}")
        print("checks:", json.dumps({"records": len(rows), "default_stale": len(stale_in_default),
                                     "history_stale": len(stale_in_history)}))
        return 0 if ok else 1

    if args.reset and TEST_STORE.exists():
        shutil.rmtree(TEST_STORE)
    TEST_STORE.mkdir(parents=True, exist_ok=True)

    mem = build_memory()
    meter = Meter(mem)
    capture = Capture(mem)

    print(f"# store={TEST_STORE} collection={TEST_COLLECTION} agent_id={TEST_AGENT_ID}")
    print("# llm=deepseek/deepseek-flash, local fastembed, MEM0_TELEMETRY=False\n")

    timings: dict[str, float] = {}
    for name, batch in (("A", ROUND_A), ("B", ROUND_B)):
        print(f"=== ROUND {name} ===")
        started = time.monotonic()
        capture.active = True
        result = mem.add(
            [{"role": role, "content": text} for role, text in batch],
            agent_id=TEST_AGENT_ID,
            metadata=round_metadata(name),
            infer=True,
        )
        capture.active = False
        timings[name] = round(time.monotonic() - started, 2)
        print(f"elapsed={timings[name]}s events={len(result.get('results', []))}")
        for row in result.get("results", []):
            print(f"  {row.get('event')} {str(row.get('id'))[:8]} {row.get('memory')}")
        if name == "B":
            print(f"captured existing_results during add: {len(capture.existing)}")
            for idx, res in enumerate(capture.existing):
                print(f"  index {idx} -> {res.id[:8]} :: {res.payload.get('data','')[:80]}")

    show(mem, "DB after both rounds (no manual edits)")

    # ---------- provenance: map linked_memory_ids to real ids, with proof ----------
    print("\n## PROVENANCE — can linked_memory_ids be trusted?")
    prompt_b = meter.prompts[-1]
    prompt_existing = parse_prompt_existing(prompt_b)
    print(f"existing memories in the prompt: {len(prompt_existing)}")
    for item in prompt_existing:
        print(f"  prompt id {item['id']}: {item['text'][:90]}")

    records = {r["memory"]: r["id"] for r in all_records(mem)}
    prompt_map: dict[str, str] = {}
    for item in prompt_existing:
        matches = [uuid for text, uuid in records.items() if text == item["text"]]
        if len(matches) == 1:
            prompt_map[item["id"]] = matches[0]
    print(f"prompt indices resolved to unique stored records: {len(prompt_map)}/{len(prompt_existing)}")
    for idx, uuid in prompt_map.items():
        print(f"  {idx} -> {uuid[:8]}")

    order_agrees = len(capture.existing) == len(prompt_existing) and all(
        capture.existing[i].id == prompt_map.get(item["id"])
        for i, item in enumerate(prompt_existing)
        if item["id"] in prompt_map
    )
    print(f"vector-store order == prompt order: {order_agrees}")
    print(f"uuid_mapping inside mem0: assigned but never read (grep: lines 937/939 only)")
    checks.append(
        (
            "index -> real id mapping proven",
            len(prompt_map) == len(prompt_existing) and order_agrees and len(prompt_map) == 2,
            f"{len(prompt_map)}/{len(prompt_existing)} resolved, order_agree={order_agrees}",
        )
    )

    linked = []
    for raw in meter.raw[-1:]:
        try:
            linked = json.loads(raw).get("memory", [])
        except json.JSONDecodeError:
            linked = []
    print("\nmodel's own linkage signal (round B):")
    cancel_indices: set[str] = set()
    for item in linked:
        print(f"  id {item.get('id')} linked_memory_ids={item.get('linked_memory_ids')} :: {item['text'][:70]}")
        if "отменено" in item["text"]:
            cancel_indices |= set(item.get("linked_memory_ids") or [])
    print(f"indices the model says it cancels: {sorted(cancel_indices)}")

    cancel_targets = [prompt_map[i] for i in sorted(cancel_indices) if i in prompt_map]
    print(f"resolved to real ids: {[u[:8] for u in cancel_targets]}")
    for uuid in cancel_targets:
        text = next((t for t, u in records.items() if u == uuid), "")
        print(f"  {uuid[:8]} :: {text[:90]}")

    k3_record = next(
        (r["id"] for r in all_records(mem) if "K3" in r["memory"] and "действующей" in r["memory"]), None
    )
    cancel_record = next((r["id"] for r in all_records(mem) if "отменено" in r["memory"]), None)
    print(f"K3 active decision: {k3_record[:8] if k3_record else None}")
    print(f"K2 cancellation record: {cancel_record[:8] if cancel_record else None}")
    checks.append(("model named exactly the K2 records", len(cancel_targets) == 2, f"{len(cancel_targets)} targets"))

    # ---------- one stock update() per cancelled record ----------
    print("\n## ACTUALISATION — update(memory_id, metadata={superseded_by, status})")
    for uuid in cancel_targets:
        res = mem.update(
            uuid,
            metadata={
                "status": "superseded",
                "superseded_by": k3_record,
                "superseded_reason_memory_id": cancel_record,
            },
        )
        print(f"  update({uuid[:8]}) -> {res}")
    show(mem, "DB after supersede metadata")

    print("\n## get(memory_id) for a superseded record")
    got = mem.get(cancel_targets[0]) if cancel_targets else None
    if got:
        print(f"  id={got['id'][:8]} memory={got['memory'][:80]}")
        print(f"  metadata={json.dumps(got.get('metadata'), ensure_ascii=False)}")

    # ---------- does a metadata flag exclude it from a plain search? ----------
    print("\n## EXCLUSION PROBE 1 — plain search, no extra filters (metadata flag only)")
    plain = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID}, top_k=5)["results"]
    print_hits(QUERY_NOW, plain)
    stale = [h for h in plain if h["id"] in cancel_targets]
    checks.append(
        (
            "plain search hides superseded (metadata flag alone)",
            not stale,
            f"{len(stale)} superseded record(s) still returned",
        )
    )

    print("\n## EXCLUSION PROBE 2 — caller-side metadata filter {'status': {'ne': 'superseded'}}")
    filtered = mem.search(
        QUERY_NOW,
        filters={"agent_id": TEST_AGENT_ID, "status": {"ne": "superseded"}},
        top_k=5,
    )["results"]
    print_hits(QUERY_NOW, filtered)
    stale2 = [h for h in filtered if h["id"] in cancel_targets]
    checks.append(
        (
            "metadata filter excludes superseded, keeps unflagged records",
            not stale2 and len(filtered) > 0,
            f"{len(stale2)} stale, {len(filtered)} kept",
        )
    )

    print("\n## EXCLUSION PROBE 3 — expiration_date = today")
    for uuid in cancel_targets:
        mem.update(uuid, expiration_date=date.today().isoformat())
    today_hits = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID}, top_k=5)["results"]
    print_hits(QUERY_NOW, today_hits)
    stale_today = [h for h in today_hits if h["id"] in cancel_targets]
    print(f"  superseded visible with expiration_date=today: {len(stale_today)}")
    checks.append(
        (
            "expiration_date=today already excludes",
            not stale_today,
            f"{len(stale_today)} still visible (day granularity)",
        )
    )

    print("\n## EXCLUSION PROBE 4 — expiration_date = yesterday (back-dated)")
    for uuid in cancel_targets:
        mem.update(uuid, expiration_date=(date.today() - timedelta(days=1)).isoformat())
    auto_hits = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID}, top_k=5)["results"]
    print_hits(QUERY_NOW, auto_hits)
    stale_auto = [h for h in auto_hits if h["id"] in cancel_targets]
    checks.append(
        (
            "plain search hides superseded with no caller filter",
            not stale_auto,
            f"{len(stale_auto)} visible",
        )
    )

    print("\n## HISTORY SEARCH — show_expired=True")
    hist = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID}, top_k=5, show_expired=True)["results"]
    print_hits(QUERY_NOW, hist)
    kept = [h for h in hist if h["id"] in cancel_targets]
    checks.append(("history search still returns superseded", len(kept) == len(cancel_targets), f"{len(kept)} found"))
    print("\n## HISTORY SEARCH — explicit filter {'status': 'superseded'}")
    only_sup = mem.search(QUERY_NOW, filters={"agent_id": TEST_AGENT_ID, "status": "superseded"}, top_k=5)["results"]
    print_hits(QUERY_NOW, only_sup)

    print(f"\n## SEARCH '{QUERY_WHY}' (reason, default)")
    print_hits(QUERY_WHY, mem.search(QUERY_WHY, filters={"agent_id": TEST_AGENT_ID}, top_k=5)["results"])
    print(f"## SEARCH '{QUERY_WHY}' (reason, show_expired=True)")
    print_hits(
        QUERY_WHY,
        mem.search(QUERY_WHY, filters={"agent_id": TEST_AGENT_ID}, top_k=5, show_expired=True)["results"],
    )

    print("\n## History events")
    for row in all_records(mem):
        for h in mem.history(row["id"]):
            print(f"- {row['id'][:8]} {h.get('event')} new={str(h.get('new_memory'))[:60]!r}")

    print("\n## CHECKS")
    for name, ok, detail in checks:
        print(f"  {'PASS' if ok else 'FAIL'}  {name} — {detail}")

    stats = meter.summary()
    print("\n## Cost")
    print(json.dumps(stats, ensure_ascii=False))
    print("round_seconds:", json.dumps(timings))

    out = ROOT / "logs" / f"m3t2b-{int(time.time())}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "collection": TEST_COLLECTION,
                "agent_id": TEST_AGENT_ID,
                "records": all_records(mem),
                "prompt_existing_map": prompt_map,
                "cancel_targets": cancel_targets,
                "k3_record": k3_record,
                "cancel_record": cancel_record,
                "raw_llm_output": meter.raw,
                "checks": [{"name": n, "ok": o, "detail": d} for n, o, d in checks],
                "cost": stats,
                "round_seconds": timings,
            },
            ensure_ascii=False,
            indent=1,
            default=str,
        )
    )
    print(f"\njson report: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
