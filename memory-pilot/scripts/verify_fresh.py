"""Open the existing store in a brand-new process and search it.

Run this only when no other process holds the store: embedded Qdrant keeps an
exclusive lock for the whole process lifetime (mem.close() does not release it),
so concurrent access is impossible and sequential access is the supported mode.
"""

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import memcfg  # noqa: E402

QUERIES = [
    ("смысловой", "что произойдёт с насосами при аварийной остановке", None),
    ("межпроектный", "проверка состояния системы и восстановление после сбоя", None),
    ("точный фильтр", "Healthcheck проверка состояния",
     {"source_path": "docs/План Этапа 5B — Healthcheck.md"}),
]


def main() -> None:
    t_open = time.perf_counter()
    mem = memcfg.memory()
    open_ms = round((time.perf_counter() - t_open) * 1000, 1)

    out = {"open_ms": open_ms, "pid": __import__("os").getpid(), "queries": []}
    for label, q, extra in QUERIES:
        filters = {"agent_id": "m2-pilot", **(extra or {})}
        t0 = time.perf_counter()
        res = mem.search(q, filters=filters, top_k=3)
        ms = round((time.perf_counter() - t0) * 1000, 1)
        rows = [{"project": (r.get("metadata") or {}).get("project_id"),
                 "source": (r.get("metadata") or {}).get("source_path"),
                 "score": round(r.get("score") or 0, 4)}
                for r in (res.get("results") or [])]
        out["queries"].append({"kind": label, "query": q, "ms": ms, "hits": rows})

    total = mem.vector_store.client.count(collection_name=memcfg.COLLECTION).count
    out["points_in_collection"] = total
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
