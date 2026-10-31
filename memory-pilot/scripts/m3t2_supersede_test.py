"""M3 test #2 — superseding a stale decision in Mem0 (add-only pipeline).

Two sequential batches in one isolated collection: round A stores the accepted
K2 decision, round B revises it to K3. Nothing is edited by hand; whatever Mem0
does with the contradiction is the result under test.

Isolated: own Qdrant dir, own collection, own history DB, own scope id. The
working store, test #1 and test #1B stores are untouched (asserted before run).

Usage:  venv/bin/python scripts/m3t2_supersede_test.py [--reset]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

ROOT = Path("/projects/memory-pilot")
TEST_STORE = ROOT / "test-m3t2" / "store"
TEST_COLLECTION = "m3t2_memories"
TEST_AGENT_ID = "m3t2-agent"
PROJECT = "TEST-VALVE-02"

from m3t1_infer_test import EMBED_DIMS, EMBED_MODEL, MODELS, deepseek_credentials  # noqa: E402
from m3t1b_infer_test import CUSTOM_INSTRUCTIONS, BatchMeter  # noqa: E402

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS))

from mem0 import Memory  # noqa: E402
from mem0.configs.base import MemoryConfig  # noqa: E402
from mem0.embeddings.configs import EmbedderConfig  # noqa: E402
from mem0.llms.configs import LlmConfig  # noqa: E402
from mem0.vector_stores.configs import VectorStoreConfig  # noqa: E402

ROUND_A = [
    (
        "user",
        "Учебный проект TEST-VALVE-02. Проверили управление клапаном V1 через выход Q0.2 "
        "и промежуточное реле K2. В учебной схеме вариант принят. Текущая документация "
        "указывает K2 как действующее решение",
    )
]

ROUND_B = [
    (
        "user",
        "В проекте TEST-VALVE-02 обнаружили, что первоначальная схема управления V1 через K2 "
        "не соответствует обновлённым требованиям. Решение K2 отменено. Проверен новый "
        "вариант: выход Q0.2 управляет промежуточным реле K3; схема с K3 прошла проверку и "
        "теперь является действующей. Старый вариант K2 сохраняется только как история "
        "отменённого решения",
    )
]

QUERIES = [
    "Как сейчас управляется V1?",
    "Почему отказались от K2?",
    "Какое решение по V1 действует?",
    "Что было раньше с V1?",
]


def build_memory() -> Memory:
    key, base_url, model = deepseek_credentials()
    assert TEST_COLLECTION not in ("m2_memories", "m3t1_memories", "m3t1b_memories")
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


def metadata(round_name: str) -> dict:
    return {
        "project_id": PROJECT,
        "project_name": "Учебный проект управления клапаном",
        "source": f"test-m3t2-{round_name}",
        "conversation_id": f"{PROJECT}/m3t2",
        "observation_date": "2026-10-31",
        "round": round_name,
    }


def dump(mem: Memory, label: str) -> list[dict]:
    items = mem.get_all(filters={"agent_id": TEST_AGENT_ID}, top_k=100)
    rows = items.get("results", items) if isinstance(items, dict) else items
    print(f"\n## {label}: {len(rows)} records")
    for number, row in enumerate(rows, start=1):
        print(f"{number}. [{row.get('id')[:8]}] {row.get('memory')}")
        print(
            f"   created={row.get('created_at')} updated={row.get('updated_at')} "
            f"meta={json.dumps({k: v for k, v in (row.get('metadata') or {}).items() if k in ('round', 'source', 'project_id')}, ensure_ascii=False)}"
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reset", action="store_true")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="fresh process: only dump records and run the 4 queries, no writes",
    )
    args = parser.parse_args()

    if args.check_only:
        mem = build_memory()
        dump(mem, "DB from a fresh process (no writes this run)")
        for query in QUERIES:
            found = mem.search(query, filters={"agent_id": TEST_AGENT_ID}, top_k=5)
            print(f"\n### {query}")
            for hit in found.get("results", []):
                print(f"  [{hit.get('score'):.3f}] [{str(hit.get('id'))[:8]}] {hit.get('memory')}")
        return 0

    if args.reset and TEST_STORE.exists():
        shutil.rmtree(TEST_STORE)
    TEST_STORE.mkdir(parents=True, exist_ok=True)

    mem = build_memory()
    assert mem.custom_instructions == CUSTOM_INSTRUCTIONS
    meter = BatchMeter(mem)

    print(f"# store={TEST_STORE}")
    print(f"# collection={TEST_COLLECTION} scope=agent_id:{TEST_AGENT_ID} project={PROJECT}")
    print("# llm=deepseek/deepseek-flash, local fastembed, MEM0_TELEMETRY=False")

    timings: dict[str, float] = {}
    round_results: dict[str, list] = {}

    for name, batch in (("A", ROUND_A), ("B", ROUND_B)):
        print(f"\n=== ROUND {name} (one add() of {len(batch)} message(s), infer=True) ===")
        started = time.monotonic()
        result = mem.add(
            [{"role": role, "content": text} for role, text in batch],
            agent_id=TEST_AGENT_ID,
            metadata=metadata(name),
            infer=True,
        )
        timings[name] = round(timings.get(name, 0) + time.monotonic() - started, 2)
        round_results[name] = result.get("results", [])
        print(f"elapsed={timings[name]}s events={len(round_results[name])}")
        for row in round_results[name]:
            print(f"  {row.get('event')} {str(row.get('id'))[:8]} {row.get('memory')}")
        dump(mem, f"DB after round {name}")

    memories = dump(mem, "DB final (no manual edits)")

    print("\n## History table")
    for row in memories:
        hist = mem.history(row["id"])
        rows = hist if isinstance(hist, list) else hist.get("results", [])
        for h in rows:
            print(
                f"- {row['id'][:8]} {h.get('event')} old={str(h.get('old_memory'))[:70]!r} "
                f"new={str(h.get('new_memory'))[:70]!r}"
            )

    print("\n## Searches after round B")
    searches = []
    for query in QUERIES:
        started = time.monotonic()
        found = mem.search(query, filters={"agent_id": TEST_AGENT_ID}, top_k=5)
        elapsed = round(time.monotonic() - started, 2)
        hits = found.get("results", [])
        searches.append({"query": query, "seconds": elapsed, "hits": hits})
        print(f"\n### {query}  ({elapsed:.2f}s)")
        for hit in hits:
            print(f"  [{hit.get('score'):.3f}] [{str(hit.get('id'))[:8]}] {hit.get('memory')}")

    print("\n## Search after a *new process* — run separately with --check-only")
    stats = meter.summary()
    print("\n## Cost")
    print(json.dumps(stats, ensure_ascii=False))
    print("round_seconds:", json.dumps(timings))
    print("per_call:", json.dumps(meter.calls, ensure_ascii=False))

    out = ROOT / "logs" / f"m3t2-{int(time.time())}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "collection": TEST_COLLECTION,
                "agent_id": TEST_AGENT_ID,
                "project": PROJECT,
                "round_a": ROUND_A,
                "round_b": ROUND_B,
                "round_results": round_results,
                "memories": memories,
                "raw_llm_output": meter.raw_responses,
                "searches": searches,
                "cost": stats,
                "round_seconds": timings,
                "llm_calls": meter.calls,
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
