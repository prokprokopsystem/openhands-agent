"""M3 test #1 — Mem0 `infer=True` fact extraction through DeepSeek.

Isolated from the working store: separate Qdrant directory, separate collection,
separate history DB, separate scope id. Nothing here touches `m2_memories`.

The DeepSeek key is decrypted in-process from the existing agent profile and is
never printed, logged, or written to disk. No OpenAI endpoint is used.

Usage:  venv/bin/python scripts/m3t1_infer_test.py [--reset]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from base64 import b64encode
from pathlib import Path

ROOT = Path("/projects/memory-pilot")
TEST_STORE = ROOT / "test-m3t1" / "store"
TEST_COLLECTION = "m3t1_memories"
TEST_AGENT_ID = "m3t1-agent"
MODELS = ROOT / "store" / "models"  # shared read-only fastembed cache
EMBED_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
EMBED_DIMS = 384
PROFILE = Path.home() / ".openhands" / "profiles" / "deepseek-chat.json"

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS))

sys.path.append("/usr/local/lib/python3.13/site-packages")
from cryptography.fernet import Fernet  # noqa: E402

from mem0 import Memory  # noqa: E402
from mem0.configs.base import MemoryConfig  # noqa: E402
from mem0.embeddings.configs import EmbedderConfig  # noqa: E402
from mem0.llms.configs import LlmConfig  # noqa: E402
from mem0.vector_stores.configs import VectorStoreConfig  # noqa: E402

CONVERSATION = [
    ("user", "Нужно наладить управление насосом P1 в учебном проекте TEST-PUMP-01."),
    (
        "assistant",
        "Сначала попробуем использовать выход Q0.0 контроллера для "
        "непосредственного подключения насоса.",
    ),
    ("user", "Проверили: так нельзя. Выход контроллера не рассчитан на питание двигателя."),
    (
        "assistant",
        "Принято. Используем выход Q0.0 только для управления катушкой промежуточного "
        "реле K1. Насос подключается через соответствующий силовой аппарат. "
        "Подбор защиты остаётся отдельной задачей.",
    ),
    (
        "user",
        "Да, такая схема прошла нашу учебную проверку. Запомни, что прямое подключение "
        "насоса к Q0.0 отвергнуто, а управление через K1 принято.",
    ),
    ("user", "Кстати, вчера был дождь, кофе остыл, а компьютер несколько раз зависал."),
    ("assistant", "Понятно"),
    (
        "user",
        "Возможно, насос P2 тоже понадобится, но пока это только предположение. "
        "Решения по P2 нет.",
    ),
    ("user", "Всё, на сегодня закончили."),
]

QUERIES = [
    "Какое решение принято для управления насосом P1?",
    "Почему отвергли прямое подключение к Q0.0?",
    "Какое окончательное решение по насосу P2?",
    "Что известно о погоде и кофе?",
]


def deepseek_credentials() -> tuple[str, str, str]:
    token = json.loads(PROFILE.read_text())["api_key"]
    secret = os.environ["OH_SECRET_KEY"].encode()
    key = Fernet(b64encode(hashlib.sha256(secret).digest())).decrypt(token.encode()).decode()
    profile = json.loads(PROFILE.read_text())
    base_url = profile["base_url"]
    model = profile["model"].split("/")[-1]  # "openai/deepseek-flash" -> DeepSeek API id
    return key, base_url, model


def build_memory() -> Memory:
    key, base_url, model = deepseek_credentials()
    assert TEST_COLLECTION != "m2_memories"
    assert TEST_STORE != ROOT / "store", "test store must not be the working store"
    config = MemoryConfig(
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
    )
    return Memory(config=config)


class LlmMeter:
    """Counts real LLM round-trips and tokens by wrapping the OpenAI client."""

    def __init__(self, mem: Memory):
        self.calls: list[dict] = []
        create = mem.llm.client.chat.completions.create

        def counted(**kwargs):
            started = time.monotonic()
            response = create(**kwargs)
            usage = getattr(response, "usage", None)
            self.calls.append(
                {
                    "model": kwargs.get("model"),
                    "prompt_tokens": getattr(usage, "prompt_tokens", None),
                    "completion_tokens": getattr(usage, "completion_tokens", None),
                    "total_tokens": getattr(usage, "total_tokens", None),
                    "seconds": round(time.monotonic() - started, 2),
                    "response_format": (kwargs.get("response_format") or {}).get("type")
                    if isinstance(kwargs.get("response_format"), dict)
                    else None,
                }
            )
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


def dump_memories(mem: Memory) -> list[dict]:
    items = mem.get_all(filters={"agent_id": TEST_AGENT_ID}, top_k=100)
    return items.get("results", items) if isinstance(items, dict) else items


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reset", action="store_true", help="drop the isolated test store")
    args = parser.parse_args()

    if args.reset and TEST_STORE.exists():
        shutil.rmtree(TEST_STORE)
    TEST_STORE.mkdir(parents=True, exist_ok=True)

    mem = build_memory()
    meter = LlmMeter(mem)

    print(f"# store={TEST_STORE} collection={TEST_COLLECTION} scope=agent_id:{TEST_AGENT_ID}")
    print(f"# llm=deepseek/{meter.calls or 'deepseek'} infer=True  (no OpenAI, no telemetry)\n")

    adds: list[dict] = []
    total_started = time.monotonic()
    for index, (role, text) in enumerate(CONVERSATION, start=1):
        started = time.monotonic()
        result = mem.add(
            [{"role": role, "content": text}],
            agent_id=TEST_AGENT_ID,
            metadata={"project_id": "TEST-PUMP-01", "turn": index},
            infer=True,
        )
        elapsed = round(time.monotonic() - started, 2)
        adds.append({"turn": index, "role": role, "text": text, "seconds": elapsed, "result": result})
        events = [
            (r.get("event"), (r.get("memory") or "")[:160]) for r in result.get("results", [])
        ]
        print(f"[turn {index} {role:9}] {elapsed:6.2f}s  -> {events or 'no events'}")
    total_elapsed = round(time.monotonic() - total_started, 2)

    print("\n## Stored memories (verbatim, agent_id=m3t1-agent)")
    memories = dump_memories(mem)
    for number, item in enumerate(memories, start=1):
        print(f"{number}. {item.get('memory')}")
        print(
            f"   id={item.get('id')} created={item.get('created_at')} "
            f"updated={item.get('updated_at')} meta={json.dumps(item.get('metadata'), ensure_ascii=False)}"
        )

    print("\n## History (what Mem0 did: ADD/UPDATE/DELETE)")
    for item in memories:
        hist = mem.history(item["id"])
        for row in hist if isinstance(hist, list) else hist.get("results", []):
            print(
                f"- {item['id'][:8]} {row.get('event')} "
                f"old={row.get('old_memory')!r} new={row.get('new_memory')!r}"
            )

    print("\n## Searches")
    searches: list[dict] = []
    for query in QUERIES:
        started = time.monotonic()
        found = mem.search(query, filters={"agent_id": TEST_AGENT_ID}, top_k=5)
        elapsed = round(time.monotonic() - started, 2)
        hits = found.get("results", [])
        searches.append({"query": query, "seconds": elapsed, "hits": hits})
        print(f"\n### {query}  ({elapsed:.2f}s, {len(hits)} hits)")
        for hit in hits:
            print(f"  [{hit.get('score'):.3f}] {hit.get('memory')}")

    stats = meter.summary()
    print("\n## Cost")
    print(json.dumps(stats, ensure_ascii=False))
    print(f"add_phase_seconds={total_elapsed} (excluding dump/search)")
    print("per_call:", json.dumps(meter.calls, ensure_ascii=False))

    out = ROOT / "logs" / f"m3t1-infer-{int(time.time())}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "collection": TEST_COLLECTION,
                "agent_id": TEST_AGENT_ID,
                "adds": adds,
                "memories": memories,
                "searches": searches,
                "cost": stats,
                "add_phase_seconds": total_elapsed,
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
