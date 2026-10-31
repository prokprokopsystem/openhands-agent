"""Measure cold start, search latency, memory and disk footprint of the pilot."""

import json
import os
import resource
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import memcfg  # noqa: E402

QUERIES = [
    "аварийная остановка насосов",
    "как восстановить доступ после пересоздания контейнера",
    "проверка состояния системы и восстановление после сбоя",
    "какие состояния у конечного автомата дозирования",
    "внешний диск и резервное копирование",
    "почему не загружается память в новом чате",
    "объёмы жидкостей по линиям",
    "ограничения доступа по сети",
    "как запускается служба проверки здоровья",
    "что делать при потере ключей SSH",
    "структура каталогов на сервере",
    "алгоритм дозирования по импульсам счётчика",
]


def du(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            fp = os.path.join(root, f)
            try:
                st = os.lstat(fp)  # do not follow symlinks (HF cache links blobs)
            except OSError:
                continue
            if not os.path.islink(fp):
                total += st.st_size
    return total


def main() -> None:
    rss_before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    t0 = time.perf_counter()
    mem = memcfg.memory()
    open_ms = round((time.perf_counter() - t0) * 1000, 1)
    rss_after_open = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024

    lat = []
    for _ in range(3):  # warm-up pass, discarded
        for q in QUERIES:
            mem.search(q, filters={"agent_id": "m2-pilot"}, top_k=5)
    for q in QUERIES:
        t = time.perf_counter()
        mem.search(q, filters={"agent_id": "m2-pilot"}, top_k=5)
        lat.append((time.perf_counter() - t) * 1000)

    rss_peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    n = mem.vector_store.client.count(collection_name=memcfg.COLLECTION).count

    disk = {
        "store_qdrant_mb": round(du(memcfg.STORE / "qdrant_db") / 1024 / 1024, 1),
        "history_db_kb": round(os.path.getsize(memcfg.STORE / "history.db") / 1024, 1),
        "models_mb": round(du(memcfg.STORE / "models") / 1024 / 1024, 1),
        "venv_mb": round(du(memcfg.ROOT / "venv") / 1024 / 1024, 1),
        "corpus_kb": round(du(memcfg.ROOT / "corpus") / 1024, 1),
        "pilot_total_mb": round(du(memcfg.ROOT) / 1024 / 1024, 1),
    }

    def stat(xs):
        xs = sorted(xs)
        return {"median": round(statistics.median(xs), 1),
                "p95": round(xs[int(len(xs) * 0.95) - 1], 1),
                "max": round(max(xs), 1), "min": round(min(xs), 1)}

    out = {
        "points_in_collection": n,
        "open_ms_cold": open_ms,
        "search_ms": stat(lat),
        "queries_measured": len(lat),
        "rss_mb_start": round(rss_before, 1),
        "rss_mb_after_model_load": round(rss_after_open, 1),
        "rss_mb_peak": round(rss_peak, 1),
        "disk": disk,
    }
    (memcfg.ROOT / "logs" / "bench.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
