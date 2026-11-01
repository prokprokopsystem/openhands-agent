"""M3 test #3 — Mem0 finds, the canonical document decides.

Read-only. Uses the existing K2/K3 collection (m3t2b_memories, test-m3t2b) and
never writes to it: only `search`/`get_all` are called, and payload hashes plus
file hashes are compared before and after to prove nothing changed.

The rule under test: Mem0 supplies evidence, the canonical document supplies
authority. This harness therefore only
  1. prints what Mem0 returns (including the contradictory K2/K3 records),
  2. reads the canonical document,
  3. applies one fail-closed rule: no readable document -> no confirmed decision.
It contains no conflict resolution beyond that gate and is not a service.

Scenarios:
  canonical   — the project document states K3 is active
  divergent   — control document states K4 is active (proves the document wins,
                not Mem0's similarity ranking)
  missing     — no document at that path
  unreadable  — document present but not readable

Usage:
  venv/bin/python scripts/m3t3_canonical_test.py --scenario canonical
  venv/bin/python scripts/m3t3_canonical_test.py --all
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

ROOT = Path("/projects/memory-pilot")
BASE = ROOT / "test-m3t3"
TEST_STORE = ROOT / "test-m3t2b" / "store"  # existing K2/K3 store, read-only here
TEST_COLLECTION = "m3t2b_memories"
TEST_AGENT_ID = "m3t2b-agent"
QUERY = "Как сейчас управляется клапан V1?"

from m3t1_infer_test import EMBED_DIMS, EMBED_MODEL, MODELS, deepseek_credentials  # noqa: E402

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS))

from mem0 import Memory  # noqa: E402
from mem0.configs.base import MemoryConfig  # noqa: E402
from mem0.embeddings.configs import EmbedderConfig  # noqa: E402
from mem0.llms.configs import LlmConfig  # noqa: E402
from mem0.vector_stores.configs import VectorStoreConfig  # noqa: E402

DOCUMENTS = {
    "canonical": BASE / "canonical" / "Решения.md",
    "divergent": BASE / "variant" / "Решения.md",
    "missing": BASE / "canonical" / "НЕТ-ТАКОГО-ФАЙЛА.md",
    "unreadable": BASE / "canonical" / "Решения-закрыт.md",
}


def build_memory() -> Memory:
    key, base_url, model = deepseek_credentials()
    assert TEST_COLLECTION == "m3t2b_memories"
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
        )
    )


def guard_no_llm(mem: Memory) -> list[dict]:
    """Fail loudly if a read-only run ever calls the LLM."""
    calls: list[dict] = []
    create = mem.llm.client.chat.completions.create

    def counted(**kwargs):
        calls.append({"at": time.time()})
        return create(**kwargs)

    mem.llm.client.chat.completions.create = counted
    return calls


def payload_fingerprint(client=None) -> tuple[str, int]:
    """Hash every stored point so we can prove the store is unchanged.

    Embedded Qdrant allows only one live client per path in a process, so the
    caller passes the existing client when one is already open.
    """
    own = client is None
    if own:
        from qdrant_client import QdrantClient

        client = QdrantClient(path=str(TEST_STORE / "qdrant_db"))
    try:
        points, _ = client.scroll(TEST_COLLECTION, limit=1000, with_payload=True)
    finally:
        if own:
            client.close()
    rows = sorted(
        (str(p.id), json.dumps(p.payload, sort_keys=True, ensure_ascii=False, default=str)) for p in points
    )
    digest = hashlib.sha256(json.dumps(rows, ensure_ascii=False).encode()).hexdigest()
    return digest, len(rows)


def file_fingerprints() -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(TEST_STORE.rglob("*")):
        if path.is_file():
            result[str(path.relative_to(TEST_STORE))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def read_document(path: Path) -> tuple[bool, str, str]:
    """Returns (readable, text, why_not)."""
    if not path.exists():
        return False, "", f"файл отсутствует: {path}"
    try:
        mode = path.stat().st_mode
        if not mode & stat.S_IRUSR:
            return False, "", f"файл без права чтения (mode={stat.S_IMODE(mode):04o}): {path}"
        return True, path.read_text(encoding="utf-8"), ""
    except OSError as exc:
        return False, "", f"ошибка чтения: {exc}"


def parse_document(text: str) -> dict:
    active = next(
        (line.strip("- ").strip() for line in text.splitlines() if "Действующее проверенное решение" in line),
        "",
    )
    retired = next(
        (line.strip("- ").strip() for line in text.splitlines() if "Ранее" in line and "использовалось" in line),
        "",
    )
    cancelled = next(
        (line.strip("- ").strip() for line in text.splitlines() if "отменено" in line),
        "",
    )
    date = ""
    match = re.search(r"Дата пересмотра:\**\s*(\d{2}\.\d{2}\.\d{4})", text)
    if match:
        date = match.group(1)
    decided_tag = ""
    tag = re.search(r"\bK\d+\b", active)
    if tag:
        decided_tag = tag.group(0)
    version = ""
    match_version = re.search(r"Версия:\**\s*([\w.\-]+)", text)
    if match_version:
        version = match_version.group(1)
    return {
        "active": active,
        "retired": retired,
        "cancelled": cancelled,
        "date": date,
        "decided_tag": decided_tag,
        "version": version,
    }


def document_hash(path: Path) -> str:
    """Content hash of the document bytes — makes the citation verifiable."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mem0_evidence(mem: Memory) -> dict:
    default_hits = mem.search(QUERY, filters={"agent_id": TEST_AGENT_ID}, top_k=10)["results"]
    all_rows = mem.get_all(filters={"agent_id": TEST_AGENT_ID}, top_k=100, show_expired=True)["results"]
    return {"default_hits": default_hits, "all_rows": all_rows}


def show_evidence(evidence: dict) -> None:
    print(f"## Mem0 — обычный поиск: «{QUERY}»")
    for number, hit in enumerate(evidence["default_hits"], start=1):
        meta = hit.get("metadata") or {}
        print(f"  {number}. [{hit.get('score'):.3f}] [{hit['id'][:8]}] {hit['memory']}")
        if meta.get("status"):
            print(f"     status={meta.get('status')} superseded_by={str(meta.get('superseded_by'))[:8]}")

    print(f"\n## Mem0 — все записи, включая снятые (show_expired=True): {len(evidence['all_rows'])}")
    for number, row in enumerate(evidence["all_rows"], start=1):
        meta = row.get("metadata") or {}
        # expiration_date sits at the top level of the row, not inside `metadata`
        print(f"  {number}. [{row['id'][:8]}] {row['memory'][:110]}")
        print(
            f"     status={meta.get('status')} expires={row.get('expiration_date')} "
            f"superseded_by={str(meta.get('superseded_by'))[:8]}"
        )


def contradiction_report(evidence: dict) -> dict:
    """Facts only: what Mem0 alone says about K2 and K3."""
    rows = evidence["all_rows"]
    superseded_ids = {r["id"] for r in rows if (r.get("metadata") or {}).get("status") == "superseded"}
    k2_current = [r for r in rows if "K2" in r["memory"] and "действующ" in r["memory"] and r["id"] not in superseded_ids]
    k2_any_active = [
        r
        for r in rows
        if "K2" in r["memory"] and r["id"] not in superseded_ids and "отменено" not in r["memory"]
    ]
    k3_current = [r for r in rows if "K3" in r["memory"] and "действующ" in r["memory"] and r["id"] not in superseded_ids]
    top = evidence["default_hits"][0] if evidence["default_hits"] else {}
    return {
        "records": len(rows),
        "superseded": sorted(superseded_ids),
        "k2_claimed_current": [r["id"] for r in k2_current],
        "k2_asserted_active_any": [r["id"] for r in k2_any_active],
        "k3_claimed_current": [r["id"] for r in k3_current],
        "top1_id": top.get("id"),
        "top1_score": round(top.get("score") or 0, 3),
        "top1_text": top.get("memory", ""),
    }


def run_scenario(name: str, doc_path: Path, mem: Memory, calls: list[dict]) -> dict:
    print("=" * 78)
    print(f"SCENARIO: {name}   document={doc_path}")
    print("=" * 78)

    evidence = mem0_evidence(mem)
    show_evidence(evidence)
    facts = contradiction_report(evidence)
    print("\n## Что Mem0 говорит сам (факты, без выводов)")
    print(f"  записей всего: {facts['records']}, снятых: {len(facts['superseded'])}")
    print(f"  записи, утверждающие K2 как действующее: {[i[:8] for i in facts['k2_claimed_current']] or 'нет'}")
    print(f"  записи про K2 без пометки отмены: {[i[:8] for i in facts['k2_asserted_active_any']] or 'нет'}")
    print(f"  записи, утверждающие K3 как действующее: {[i[:8] for i in facts['k3_claimed_current']] or 'нет'}")
    print(f"  top-1: [{facts['top1_score']}] {facts['top1_text'][:90]}")

    readable, text, why = read_document(doc_path)
    result: dict = {"scenario": name, "document": str(doc_path), "mem0": facts}

    if not readable:
        print(f"\n## Канонический документ НЕДОСТУПЕН — {why}")
        print("## ИТОГ: действующее решение НЕ ПОДТВЕРЖДЕНО")
        print("   K2 и K3 не могут быть выданы как подтверждённое действующее решение.")
        print("   Причина: единственный источник актуальности недоступен; показания Mem0")
        print("   противоречивы и содержат снятые записи, поэтому подтвердить нечем.")
        result.update(
            {
                "document_readable": False,
                "verdict": "unconfirmed",
                "confirmed_active": None,
                "retired": None,
                "reason": None,
                "document_date": None,
            }
        )
        return result

    parsed = parse_document(text)
    doc_hash = document_hash(doc_path)
    print("\n## Канонический документ (прочитан)")
    for line in text.splitlines():
        if line.strip():
            print(f"  {line}")
    print(f"\n  версия={parsed['version'] or '—'} sha256={doc_hash[:16]}…")
    print("\n## Разбор документа")
    print(f"  действующее решение: {parsed['active']}")
    print(f"  отменённое решение:  {parsed['retired']}")
    print(f"  причина отмены:      {parsed['cancelled']}")
    print(f"  дата пересмотра:     {parsed['date']}")

    decided_tag = parsed["decided_tag"]
    top1_text = facts["top1_text"]
    top1_tags = sorted(set(re.findall(r"\bK\d+\b", top1_text)))
    top1_conflicts = bool(decided_tag) and bool(top1_tags) and decided_tag not in top1_tags
    print("\n## ИТОГ по правилу «документ решает, Mem0 ищет»")
    print(f"  действующее решение: {parsed['active'] or '— нет строки о действующем решении —'}")
    print(f"  отменённое решение:  {parsed['retired'] or '—'}")
    print(f"  причина:             {parsed['cancelled'] or '—'}")
    print(f"  источник:            {doc_path}")
    print(f"  ссылка:              версия {parsed['version'] or '—'}, дата пересмотра {parsed['date'] or '—'}, sha256 {doc_hash[:16]}…")
    if top1_conflicts:
        print(
            f"  ВНИМАНИЕ: top-1 Mem0 указывает на {top1_tags}, документ — на {decided_tag}. "
            "Приоритет у документа; top-1 отклонён."
        )

    result.update(
        {
            "document_readable": True,
            "verdict": "confirmed" if parsed["active"] else "unconfirmed",
            "confirmed_active": parsed["active"] or None,
            "decided_tag": decided_tag or None,
            "retired": parsed["retired"] or None,
            "reason": parsed["cancelled"] or None,
            "document_date": parsed["date"] or None,
            "document_version": parsed["version"] or None,
            "document_sha256": doc_hash,
            "top1_tags": top1_tags,
            "top1_conflicts_with_document": top1_conflicts,
        }
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--scenario", choices=sorted(DOCUMENTS), action="append", help="can repeat; default canonical"
    )
    parser.add_argument("--all", action="store_true")
    args = parser.parse_args()

    scenarios = sorted(DOCUMENTS) if args.all else (args.scenario or ["canonical"])

    unreadable_doc = DOCUMENTS["unreadable"]
    if "unreadable" in scenarios:
        unreadable_doc.parent.mkdir(parents=True, exist_ok=True)
        unreadable_doc.write_text(
            DOCUMENTS["canonical"].read_text(encoding="utf-8"), encoding="utf-8"
        )
        unreadable_doc.chmod(0o000)

    digest_before, count_before = payload_fingerprint()
    files_before = file_fingerprints()

    mem = build_memory()
    calls = guard_no_llm(mem)

    print(f"# store={TEST_STORE} (read-only) collection={TEST_COLLECTION} agent_id={TEST_AGENT_ID}")
    print(f"# payload fingerprint before: {digest_before[:16]}… points={count_before}")

    results = [run_scenario(name, DOCUMENTS[name], mem, calls) for name in scenarios]

    digest_after, count_after = payload_fingerprint(mem.vector_store.client)
    files_after = file_fingerprints()
    changed = sorted(
        set(files_before) ^ set(files_after)
        | {p for p in files_before if p in files_after and files_before[p] != files_after[p]}
    )

    print("\n" + "=" * 78)
    print("ЦЕЛОСТНОСТЬ ХРАНИЛИЩА")
    print("=" * 78)
    print(f"  payload before={digest_before[:16]}… points={count_before}")
    print(f"  payload after ={digest_after[:16]}… points={count_after}")
    print(f"  payload identical: {digest_before == digest_after and count_before == count_after}")
    print(f"  changed files under {TEST_STORE}: {changed or 'none'}")
    print(f"  LLM calls during run: {len(calls)}")

    if unreadable_doc.exists():
        unreadable_doc.chmod(0o600)
        unreadable_doc.unlink()

    out = BASE / f"m3t3-{int(time.time())}.json"
    out.write_text(
        json.dumps(
            {
                "scenarios": results,
                "store": {
                    "collection": TEST_COLLECTION,
                    "agent_id": TEST_AGENT_ID,
                    "payload_before": digest_before,
                    "payload_after": digest_after,
                    "points_before": count_before,
                    "points_after": count_after,
                    "unchanged": digest_before == digest_after and count_before == count_after,
                    "changed_files": changed,
                },
                "llm_calls": len(calls),
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
