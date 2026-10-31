"""Ingest the M2 corpus into Mem0 with infer=False (no LLM calls, no cost).

Idempotent: a local ledger of (sha256, section) keys prevents duplicates on
re-run. Records are stored verbatim with provenance metadata.
"""

import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import memcfg  # noqa: E402

MANIFESTS = memcfg.ROOT / "manifests"
LOGS = memcfg.ROOT / "logs"
LEDGER = MANIFESTS / "ingested.json"
AGENT_ID = "m2-pilot"


def load_ledger() -> dict:
    if LEDGER.exists():
        return json.loads(LEDGER.read_text(encoding="utf-8"))
    return {}


def save_ledger(ledger: dict) -> None:
    LEDGER.write_text(json.dumps(ledger, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    records = json.loads((MANIFESTS / "corpus.json").read_text(encoding="utf-8"))
    ledger = load_ledger()
    mem = memcfg.memory()

    added, skipped, failures = 0, 0, []
    times = []
    for rec in records:
        key = f"{rec['sha256'][:16]}:{rec['section']}"
        if key in ledger:
            skipped += 1
            continue
        meta = {
            "project_id": rec["project_id"],
            "source_path": rec["source_path"],
            "sha256": rec["sha256"],
            "doc_date": rec["date"],
            "section": rec["section"],
            "valid_from": "2026-10-31",
            "superseded_by": None,
        }
        t0 = time.perf_counter()
        try:
            res = mem.add(
                [{"role": "user", "content": rec["text"]}],
                agent_id=AGENT_ID,
                metadata=meta,
                infer=False,
            )
            elapsed = time.perf_counter() - t0
            times.append(elapsed)
            ids = [r.get("id") for r in (res.get("results") or [])]
            ledger[key] = {"ids": ids, "project_id": rec["project_id"],
                           "source_path": rec["source_path"], "seconds": round(elapsed, 3)}
            added += 1
        except Exception as exc:  # keep going, report at the end
            failures.append((key, type(exc).__name__, str(exc)[:200]))

    save_ledger(ledger)

    summary = {
        "added": added,
        "skipped_existing": skipped,
        "failed": len(failures),
        "failures": failures,
        "add_seconds_median": round(statistics.median(times), 3) if times else None,
        "add_seconds_max": round(max(times), 3) if times else None,
        "total_records_in_ledger": len(ledger),
    }
    (LOGS / "ingest-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
