"""M3 test #1B — same conversation, one batch, with Mem0 `custom_instructions`.

Isolated: own Qdrant dir, own collection, own history DB, own scope id.
Working store (`m2_memories`) and test #1 store (`m3t1_memories`) untouched.

Usage:  venv/bin/python scripts/m3t1b_infer_test.py [--reset]
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
TEST_STORE = ROOT / "test-m3t1b" / "store"
TEST_COLLECTION = "m3t1b_memories"
TEST_AGENT_ID = "m3t1b-agent"

from m3t1_infer_test import (  # noqa: E402
    CONVERSATION,
    EMBED_DIMS,
    EMBED_MODEL,
    MODELS,
    QUERIES,
    deepseek_credentials,
)

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS))

from mem0 import Memory  # noqa: E402
from mem0.configs.base import MemoryConfig  # noqa: E402
from mem0.embeddings.configs import EmbedderConfig  # noqa: E402
from mem0.llms.configs import LlmConfig  # noqa: E402
from mem0.vector_stores.configs import VectorStoreConfig  # noqa: E402

CUSTOM_INSTRUCTIONS = """\
Ты ведёшь техническую память учебного проекта. Соблюдай правила строго.

1. СОХРАНЯЙ только: проверенные технические факты; принятые решения; причины ошибок и отказов; \
ограничения и условия; незавершённые задачи и открытые вопросы.
2. НЕ СОХРАНЯЙ бытовую болтовню, погоду, самочувствие, еду, мелкие бытовые неполадки и любые \
сведения, не относящиеся к делу проекта. Если реплика не содержит проектного смысла — не создавай запись.
3. РАЗЛИЧАЙ статус сведения и всегда указывай его явно:
   - «предложение» — вариант, который лишь обсуждался;
   - «предположение» — не подтверждённая возможность, решения нет;
   - «проверенный результат» — то, что подтверждено испытанием или проверкой;
   - «решение» — окончательно принято.
   Отвергнутый вариант помечай как отвергнутый и указывай причину. Никогда не превращай \
предположение в решение.
4. ЯЗЫК: все записи формулируй по-русски, даже если реплики на другом языке. Технические \
обозначения (Q0.0, K1, P1, P2) оставляй как есть.
5. ФОРМА: краткий самостоятельный факт в третьем лице, без пересказа диалога и без оборотов \
«Agent was informed», «пользователь сказал». Запись должна быть понятна без контекста беседы.
6. НЕ ВЫДУМЫВАЙ отсутствующие сведения: если данных нет — не дополняй их по смыслу.
"""


class BatchMeter:
    """Counts LLM round-trips, tokens and keeps the raw extraction JSON."""

    def __init__(self, mem: Memory):
        self.calls: list[dict] = []
        self.raw_responses: list[str] = []
        create = mem.llm.client.chat.completions.create

        def counted(**kwargs):
            started = time.monotonic()
            response = create(**kwargs)
            usage = getattr(response, "usage", None)
            user_prompt = next(
                (m["content"] for m in kwargs.get("messages", []) if m.get("role") == "user"), ""
            )
            self.calls.append(
                {
                    "model": kwargs.get("model"),
                    "prompt_tokens": getattr(usage, "prompt_tokens", None),
                    "completion_tokens": getattr(usage, "completion_tokens", None),
                    "total_tokens": getattr(usage, "total_tokens", None),
                    "seconds": round(time.monotonic() - started, 2),
                    "user_prompt_chars": len(user_prompt),
                    "custom_section_present": "## Custom Instructions" in user_prompt,
                    "custom_section_chars": len(user_prompt.split("## Custom Instructions")[-1])
                    if "## Custom Instructions" in user_prompt
                    else 0,
                }
            )
            content = response.choices[0].message.content
            if isinstance(content, str):
                self.raw_responses.append(content)
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


def build_memory() -> Memory:
    key, base_url, model = deepseek_credentials()
    assert TEST_COLLECTION not in ("m2_memories", "m3t1_memories")
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
        ),
    )


METADATA = {
    "project_id": "TEST-PUMP-01",
    "project_name": "Учебный проект управления насосом",
    "source": "test-m3t1b-batch",
    "conversation_id": "TEST-PUMP-01/m3t1b",
    "observation_date": "2026-10-31",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reset", action="store_true")
    args = parser.parse_args()

    if args.reset and TEST_STORE.exists():
        shutil.rmtree(TEST_STORE)
    TEST_STORE.mkdir(parents=True, exist_ok=True)

    mem = build_memory()
    assert mem.custom_instructions == CUSTOM_INSTRUCTIONS
    meter = BatchMeter(mem)

    print(f"# store={TEST_STORE}")
    print(f"# collection={TEST_COLLECTION} scope=agent_id:{TEST_AGENT_ID}")
    print(f"# mode=BATCH (all {len(CONVERSATION)} messages in one add()) infer=True")
    print(f"# custom_instructions={len(CUSTOM_INSTRUCTIONS)} chars\n")

    batch = [{"role": role, "content": text} for role, text in CONVERSATION]
    started = time.monotonic()
    result = mem.add(batch, agent_id=TEST_AGENT_ID, metadata=METADATA, infer=True)
    elapsed = round(time.monotonic() - started, 2)

    print(f"## Batch add: {elapsed:.2f}s, events={len(result.get('results', []))}")
    for row in result.get("results", []):
        print(f"  {row.get('event')} {row.get('id')[:8]} {row.get('memory')}")

    print("\n## Stored memories (verbatim)")
    items = mem.get_all(filters={"agent_id": TEST_AGENT_ID}, top_k=100)
    memories = items.get("results", items) if isinstance(items, dict) else items
    for number, item in enumerate(memories, start=1):
        print(f"{number}. {item.get('memory')}")
        print(f"   id={item.get('id')} meta={json.dumps(item.get('metadata'), ensure_ascii=False)}")

    print("\n## Payload keys actually persisted")
    # Reuse the memory's own client: embedded Qdrant locks the dir per process,
    # so a second QdrantClient on the same path raises RuntimeError.
    points, _ = mem.vector_store.client.scroll(TEST_COLLECTION, limit=100, with_payload=True)
    if points:
        print("keys:", sorted(points[0].payload.keys()))
        print("attributed_to:", sorted({str(p.payload.get("attributed_to")) for p in points}))
        print("per-record source-ish fields:", [
            {k: v for k, v in p.payload.items() if k in ("source", "turn", "message_id", "attributed_to")}
            for p in points
        ])
    print(f"points={len(points)}")

    print("\n## Raw LLM extraction output (what the model returned)")
    raw = meter.raw_responses[0] if meter.raw_responses else "(none)"
    print(raw[:2000])

    print("\n## History")
    for item in memories:
        hist = mem.history(item["id"])
        rows = hist if isinstance(hist, list) else hist.get("results", [])
        for row in rows:
            print(f"- {item['id'][:8]} {row.get('event')}")

    print("\n## Searches")
    searches = []
    for query in QUERIES:
        q_started = time.monotonic()
        found = mem.search(query, filters={"agent_id": TEST_AGENT_ID}, top_k=5)
        q_elapsed = round(time.monotonic() - q_started, 2)
        hits = found.get("results", [])
        searches.append({"query": query, "seconds": q_elapsed, "hits": hits})
        print(f"\n### {query}  ({q_elapsed:.2f}s, {len(hits)} hits)")
        for hit in hits:
            print(f"  [{hit.get('score'):.3f}] {hit.get('memory')}")

    stats = meter.summary()
    print("\n## Cost")
    print(json.dumps(stats, ensure_ascii=False))
    print(f"add_seconds={elapsed}")
    print("per_call:", json.dumps(meter.calls, ensure_ascii=False))

    out = ROOT / "logs" / f"m3t1b-infer-{int(time.time())}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "collection": TEST_COLLECTION,
                "agent_id": TEST_AGENT_ID,
                "custom_instructions": CUSTOM_INSTRUCTIONS,
                "metadata": METADATA,
                "batch_result": result,
                "memories": memories,
                "payload_keys": sorted(points[0].payload.keys()) if points else [],
                "raw_llm_output": meter.raw_responses,
                "searches": searches,
                "cost": stats,
                "add_seconds": elapsed,
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
