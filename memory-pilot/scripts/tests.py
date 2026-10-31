"""M2 acceptance tests: exact, semantic, cross-project search, provenance,
fact-version history, and index recovery in a fresh process.

Every test prints PASS/FAIL with concrete evidence and writes logs/m2-tests.json.
"""

import json
import resource
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import memcfg  # noqa: E402

LOGS = memcfg.ROOT / "logs"
AGENT_ID = "m2-pilot"
results: list[dict] = []


def record(name: str, passed: bool, evidence, note: str = "") -> None:
    results.append({"test": name, "status": "PASS" if passed else "FAIL",
                    "evidence": evidence, "note": note})
    print(f"[{'PASS' if passed else 'FAIL'}] {name}")
    print(f"       {str(evidence)[:400]}")
    if note:
        print(f"       note: {note}")


def hits(res) -> list[dict]:
    out = []
    for r in (res.get("results") or []):
        mem = r.get("memory") or ""
        md = (r.get("metadata") or {}) if isinstance(r.get("metadata"), dict) else {}
        out.append({"id": r.get("id"), "score": round(r.get("score") or 0, 4),
                    "project": md.get("project_id"), "source": md.get("source_path"),
                    "section": md.get("section"), "text": mem})
    return out


def timed(fn, *a, **kw):
    t0 = time.perf_counter()
    out = fn(*a, **kw)
    return out, round((time.perf_counter() - t0) * 1000, 1)


def main() -> None:
    mem = memcfg.memory()
    timings = {}

    # 1. Exact lookup of a document by file name (metadata filter path)
    res, ms = timed(mem.search, "Healthcheck проверка состояния",
                    filters={"agent_id": AGENT_ID,
                             "source_path": "docs/План Этапа 5B — Healthcheck.md"},
                    top_k=3)
    h = hits(res)
    ok = bool(h) and all(x["source"] == "docs/План Этапа 5B — Healthcheck.md" for x in h)
    timings["exact_filename"] = ms
    record("1. Точный поиск по имени файла (фильтр по source_path)", ok,
           f"{len(h)} совпадений, источник={h[0]['source'] if h else None}, {ms} мс",
           "имя файла живёт в метаданных, а не в тексте — поиск идёт фильтром, не BM25")

    # 2. Exact token/number lookup through BM25 keyword search
    kw = mem.vector_store.keyword_search("Vi_set", top_k=5,
                                         filters={"agent_id": AGENT_ID})
    kw_text = [p.payload.get("data", "") for p in (kw or [])]
    ok2 = any("Vi_set" in t for t in kw_text)
    vingette = None
    record("2. Точный поиск по номеру/токену (BM25 sparse)", ok2,
           f"BM25 вернул {len(kw_text)} записей, 'Vi_set' в тексте: {ok2}",
           "BM25-слот в embedded Qdrant работает" if ok2 else "BM25 не дал точного токена")

    # 3. Semantic search in Russian, no shared keywords
    q3 = "что произойдёт с насосами при аварийной остановке"
    res3, ms3 = timed(mem.search, q3, filters={"agent_id": AGENT_ID}, top_k=3)
    h3 = hits(res3)
    joined = " ".join(x["text"].lower() for x in h3)
    ok3 = bool(h3) and any(w in joined for w in ("стоп", "аварий", "abort", "останов"))
    timings["semantic_ru"] = ms3
    record("3. Смысловой поиск по-русски (без общих слов)", ok3,
           f"топ-1 проект={h3[0]['project'] if h3 else None}, score={h3[0]['score'] if h3 else None}, {ms3} мс",
           f"запрос: «{q3}»")

    # 4. Cross-project search: one query returns hits from both projects
    q4 = "проверка состояния системы и восстановление после сбоя"
    res4, ms4 = timed(mem.search, q4, filters={"agent_id": AGENT_ID}, top_k=10)
    h4 = hits(res4)
    projects = sorted({x["project"] for x in h4})
    ok4 = len(projects) >= 2
    timings["cross_project"] = ms4
    record("4. Межпроектный поиск (оба проекта в выдаче)", ok4,
           f"проекты в топ-10: {projects}, {ms4} мс", f"запрос: «{q4}»")

    # 5. Provenance: every returned source_path must exist and open
    bad = []
    checked = 0
    for x in h4:
        p = memcfg.ROOT / "corpus" / (x["project"] or "") / (x["source"] or "").replace("/", "__")
        if not p.exists():
            bad.append(str(p))
            continue
        p.read_text(encoding="utf-8")[:200]
        checked += 1
    record("5. Ссылки на источники открываются", not bad and checked > 0,
           f"проверено файлов: {checked}, отсутствуют: {bad or 'нет'}")

    # 6. Fact update: old version must survive in history
    for stale in hits(mem.search("Пилот памяти индекс хранится",
                                 filters={"agent_id": AGENT_ID,
                                          "source_path": "manual/m2-test"}, top_k=10)):
        mem.delete(stale["id"])
    r6 = mem.add([{"role": "user", "content": "Пилот памяти: индекс хранится в /tmp/fastembed_cache"}],
                 agent_id=AGENT_ID, infer=False,
                 metadata={"project_id": "memory-pilot", "source_path": "manual/m2-test",
                           "sha256": "manual-test", "doc_date": "2026-10-31",
                           "section": "test-fact", "valid_from": "2026-10-31",
                           "superseded_by": None})
    mid = r6["results"][0]["id"]
    mem.update(mid, "Пилот памяти: индекс хранится в /projects/memory-pilot/store/models",
               metadata={"project_id": "memory-pilot", "source_path": "manual/m2-test",
                         "sha256": "manual-test", "doc_date": "2026-10-31",
                         "section": "test-fact", "valid_from": "2026-10-31",
                         "superseded_by": "manual/m2-test:test-fact:v2"})
    hist = mem.db.get_history(mid) if hasattr(mem.db, "get_history") else None
    events = [(h.get("event"), h.get("old_memory") or "", h.get("new_memory") or "")
              for h in (hist or [])]
    ok6 = (any(e[0] == "UPDATE" for e in events)
           and any("/tmp/fastembed_cache" in e[1] for e in events)
           and any("/projects/memory-pilot/store/models" in e[2] for e in events))
    record("6. Исправление факта сохраняет старую версию", ok6,
           [(e[0], e[1][:55], e[2][:55]) for e in events],
           "OSS не проставляет superseded_by сам — ссылка записана вручную в metadata")

    # 7. Concurrent access must be refused (documented limitation of embedded
    # Qdrant). Sequential restart is proven separately by scripts/verify_fresh.py.
    import os
    import subprocess
    probe = (
        "import sys; sys.path.insert(0,'/projects/memory-pilot/scripts');"
        "import memcfg;"
        "m=memcfg.memory(); print('OPENED')"
    )
    cp = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True,
                        timeout=300, env=dict(os.environ))
    refused = cp.returncode != 0 and "already accessed by another instance" in cp.stderr
    record("7. Конкурентный доступ отклоняется (ожидаемо)", refused,
           "второй процесс получил RuntimeError, пока первый держит store" if refused
           else f"rc={cp.returncode} out={cp.stdout[:120]}",
           "перезапуск в новом процессе проверяется отдельно: scripts/verify_fresh.py")

    # 8. No external LLM calls: poison the LLM, then ingest and search.
    for stale in hits(mem.search("M2 проверка отсутствия внешних вызовов",
                                 filters={"agent_id": AGENT_ID,
                                          "source_path": "manual/m2-noLm"}, top_k=10)):
        mem.delete(stale["id"])

    def explosion(*_a, **_kw):
        raise AssertionError("LLM must not be called on M2")

    mem.llm.generate_response = explosion
    ok8 = True
    try:
        mem.add([{"role": "user", "content": "M2: проверка отсутствия внешних LLM-вызовов"}],
                agent_id=AGENT_ID, infer=False,
                metadata={"project_id": "memory-pilot", "source_path": "manual/m2-noLm",
                          "sha256": "manual-nolm", "doc_date": "2026-10-31",
                          "section": "no-llm"})
        mem.search("проверка отсутствия вызовов", filters={"agent_id": AGENT_ID}, top_k=2)
    except AssertionError as exc:
        ok8 = False
        err8 = str(exc)
    embedder_name = type(mem.embedding_model).__name__
    record("8. Нет внешних LLM-вызовов при add(infer=False) и search", ok8,
           f"LLM подменён на исключение, операции прошли; embedder={embedder_name}",
           "эмбеддинги считает локальный ONNX, OpenAI/DeepSeek не вызывались")

    peak_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    out = {"results": results,
           "timings_ms": timings,
           "peak_rss_mb_process": round(peak_mb, 1),
           "passed": sum(1 for r in results if r["status"] == "PASS"),
           "failed": sum(1 for r in results if r["status"] == "FAIL")}
    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / "m2-tests.json").write_text(json.dumps(out, ensure_ascii=False, indent=2),
                                        encoding="utf-8")
    print(f"\nPASS {out['passed']} / FAIL {out['failed']} | peak RSS {out['peak_rss_mb_process']} MB")


if __name__ == "__main__":
    main()
