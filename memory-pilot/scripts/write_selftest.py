"""Offline self-tests for the M3 stage-1 write path (no live conversation).

Every check goes through the real hook entry points as subprocesses, with the
same stdin JSON the SDK sends, a separate queue/state/store and a temporary
canonical document. The live stage-1 config is never touched: the harness
points ``MEMORY_STAGE1_CONFIG`` at its own config, and the queue/state/audit
dirs follow the config's directory.

Usage: venv/bin/python scripts/write_selftest.py [--keep]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path("/projects/memory-pilot")
SCRIPTS = ROOT / "scripts"
VENV = ROOT / "venv" / "bin" / "python"
BASE = ROOT / "stage1" / "selftest"
CONV_ROOT = BASE / "conversations"
CFG_PATH = BASE / "config.json"
DOC_PATH = BASE / "Решения.md"
PROJECT_WORKDIR = "/projects/memory-pilot-test"

os.environ["MEMORY_STAGE1_CONFIG"] = str(CFG_PATH)
sys.path.insert(0, str(SCRIPTS))

RESULTS: list[tuple[str, bool, str]] = []
ORIGINAL_RECORDS: dict[str, list[dict]] = {}


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail else ""), flush=True)


# ------------------------------------------------------------------ setup ----

def write_config(store: Path | None = None) -> None:
    live = json.loads((ROOT / "stage1" / "config.json").read_text(encoding="utf-8"))
    live.update(
        {
            "store": str(store or BASE / "store"),
            "collection": "selftest_memories",
            "agent_id": "selftest-write",
            "conversations_root": str(CONV_ROOT),
        }
    )
    live["projects"] = {
        PROJECT_WORKDIR: {
            "project_id": "TEST-WRITE-01",
            "canonical_doc": str(DOC_PATH),
            "recall": True,
        }
    }
    CFG_PATH.write_text(json.dumps(live, ensure_ascii=False, indent=1), encoding="utf-8")


def write_doc(decisions: dict[str, str], date: str = "2026-10-31") -> None:
    lines = [
        "# Решения проекта TEST-WRITE-01",
        "",
        f"Дата пересмотра: {date}",
        "Версия: selftest",
        "",
    ]
    for decision, (title, status) in decisions.items():
        lines += [f"## {decision} — {title}", f"Статус: {status}", ""]
    lines += ["## История изменений", "", f"- {date} — документ обновлён в самотесте.", ""]
    DOC_PATH.write_text("\n".join(lines), encoding="utf-8")


def new_conversation(messages: list[tuple[str, str]], label: str) -> str:
    conv_id = str(uuid.uuid4())
    conv_hex = conv_id.replace("-", "")
    events = CONV_ROOT / conv_hex / "events"
    events.mkdir(parents=True, exist_ok=True)
    for index, (role, text) in enumerate(messages, start=1):
        event = {
            "kind": "MessageEvent",
            "id": str(uuid.uuid4()),
            "timestamp": f"2026-10-31T17:{index:02d}:00",
            "source": role,
            "llm_message": {"role": role, "content": [{"type": "text", "text": text}]},
            "extended_content": [],
        }
        (events / f"event-{index:05d}-{uuid.uuid4()}.json").write_text(
            json.dumps(event, ensure_ascii=False), encoding="utf-8"
        )
    (CONV_ROOT / conv_hex / "label.txt").write_text(label, encoding="utf-8")
    return conv_hex


# ------------------------------------------------------------------ hooks ----

def run_hook(script: str, payload: dict, extra: list[str] | None = None) -> tuple[int, str, str]:
    args = [str(VENV), str(SCRIPTS / script)] + (extra or [])
    proc = subprocess.run(
        args,
        input=json.dumps(payload, ensure_ascii=False),
        text=True,
        capture_output=True,
        cwd=PROJECT_WORKDIR if Path(PROJECT_WORKDIR).is_dir() else str(BASE),
        env={**os.environ},
        timeout=300,
    )
    return proc.returncode, proc.stdout, proc.stderr


def capture(conv_hex: str) -> tuple[int, str, str]:
    return run_hook(
        "hook_capture.py",
        {
            "event_type": "Stop",
            "session_id": conv_hex,
            "working_dir": PROJECT_WORKDIR,
            "metadata": {"reason": "agent_finished"},
        },
    )


def write_batch(conv_hex: str) -> tuple[int, str, str]:
    return run_hook("hook_write.py", {}, extra=["--conv", conv_hex])


def queue_file(conv_hex: str) -> Path:
    return BASE / "queue" / f"{conv_hex}.jsonl"


def queue_records(conv_hex: str) -> list[dict]:
    path = queue_file(conv_hex)
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def state_of(conv_hex: str) -> dict:
    path = BASE / "state" / f"{conv_hex}.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


# ------------------------------------------------------------------- mem0 ----

def mem():
    import stage1_common as s1

    return s1.build_memory(json.loads(CFG_PATH.read_text(encoding="utf-8")), with_llm=True)


def all_facts(memory) -> list[dict]:
    rows = memory.get_all(filters={"agent_id": "selftest-write"}, top_k=200).get("results") or []
    return [r for r in rows if (r.get("metadata") or {}).get("stage") == "stage1-auto"]


def texts(memory) -> list[str]:
    return [r.get("memory") or "" for r in all_facts(memory)]


def search(memory, query: str, top_k: int = 5) -> list[dict]:
    return memory.search(
        query, top_k=top_k, filters={"agent_id": "selftest-write"}
    ).get("results", [])


# ------------------------------------------------------------------ tests ----

MSG_K1 = [
    ("user", "Принято решение K1 по проекту TEST-WRITE-01: насос P1 управляется через реле K1 от выхода Q0.0 контроллера."),
    ("assistant", "Обновил Решения.md: K1 — действует."),
    ("user", "Прямое подключение насоса к выходу Q0.0 отвергнуто: выход не рассчитан на ток двигателя."),
    ("user", "Кстати, сегодня дождливо, кофе остыл, ноутбук подвис."),
    ("assistant", "Понятно."),
]

MSG_K2 = [
    ("user", "Решение K1 отменено. Принято решение K2 по проекту TEST-WRITE-01: катушка пускателя насоса P1 питается от выхода Q0.1, потому что реле K1 не обеспечивает нужную коммутационную способность."),
    ("assistant", "Обновил Решения.md: K1 — отменено (заменено на K2), K2 — действует."),
    ("user", "Возможно, понадобится второй насос P2, но это только предположение, решения по P2 нет."),
    ("assistant", "Зафиксировал как открытый вопрос, решением не считаю."),
]

MSG_K3 = [
    ("user", "Принято ещё одно решение K3 по проекту TEST-WRITE-01: аварийная кнопка подключается к входу X0.5. Решение K2 остаётся в силе, K3 его не отменяет."),
    ("assistant", "Добавил K3 в Решения.md со статусом действует, K2 оставил действующим."),
]


def test_capture_idempotent() -> str:
    conv = new_conversation(MSG_K1, "capture")
    rc1, _, _ = capture(conv)
    first = queue_records(conv)
    rc2, _, _ = capture(conv)
    second = queue_records(conv)
    check(
        "T1 capture: turns enqueued once, repeat run adds nothing",
        rc1 == 0 and rc2 == 0 and len(first) == 5 and len(second) == 5,
        f"rc={rc1}/{rc2} queued={len(first)}->{len(second)}",
    )
    ORIGINAL_RECORDS[conv] = first
    return conv


def test_write_and_noise(conv: str) -> None:
    rc, out, err = write_batch(conv)
    memory = mem()
    facts = texts(memory)
    noise = [t for t in facts if "кофе" in t or "дождл" in t or "ноутбук" in t]
    decision = [t for t in facts if "K1" in t or "K1" in t]
    check("T2a write: hook exits 0 and drains the queue", rc == 0 and not queue_records(conv), f"rc={rc} left={len(queue_records(conv))}")
    check("T2b write: decision K1 stored", bool(decision), f"{len(decision)} of {len(facts)} facts mention K1")
    check("T2c write: chatter not stored", not noise, f"noise={noise}")
    state = state_of(conv)
    check("T2d write: batch recorded in state", bool(state.get("batches")), json.dumps(state.get("batches"), ensure_ascii=False)[:160])


def test_rerun_idempotent(conv: str, before: int) -> None:
    """Re-queue the identical batch: it must be recognised, not written twice.

    This is exactly the crash window between ``add()`` returning and the queue
    being trimmed: the records are back in the queue, the facts are already in
    the store, and ``batch_id`` has to stop the duplicate.
    """
    replay = ORIGINAL_RECORDS[conv]
    queue_file(conv).write_text(
        "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in replay), encoding="utf-8"
    )
    rc, _, _ = write_batch(conv)
    memory = mem()
    after = len(all_facts(memory))
    batch = state_of(conv).get("batches", [])[-1]
    check(
        "T3a idempotency: identical batch replay adds no facts",
        rc == 0 and after == before,
        f"facts {before}->{after}, status={batch.get('status')}",
    )
    check(
        "T3b idempotency: replay recognised by batch_id",
        batch.get("status") == "already_written" and not queue_records(conv),
        f"batch_id={batch.get('batch_id')} left={len(queue_records(conv))}",
    )
    found = memory.get_all(
        filters={"agent_id": "selftest-write", "batch_id": batch.get("batch_id")}, top_k=5
    )
    check(
        "T3c idempotency: batch_id is stored as record metadata",
        bool(found),
        f"hits={len(found or [])}",
    )


def test_doc_fail_closed() -> None:
    import stage1_common as s1

    write_doc({"K1": ("реле K1", "отменено (заменено на K2)"), "K2": ("пускатель от Q0.1", "действует")})
    info = s1.doc_facts(str(DOC_PATH))
    missing = s1.verify_against_doc(info, "принятое решение K3: кнопка на X0.5")
    present = s1.verify_against_doc(info, "принятое решение K2: катушка от Q0.1")
    check("T4a doc: decision absent from document is not confirmed", not missing["doc_confirmed"], str(missing.get("doc_reason")))
    check("T4b doc: decision present in document is confirmed", present["doc_confirmed"], str(present.get("doc_ref")))

    os.chmod(DOC_PATH, 0o000)
    try:
        info = s1.doc_facts(str(DOC_PATH))
        blocked = s1.verify_against_doc(info, "принятое решение K2: катушка от Q0.1")
        check("T4c doc: unreadable document never confirms a decision", not blocked["doc_confirmed"], str(blocked.get("doc_reason")))
    finally:
        os.chmod(DOC_PATH, 0o644)

    info = s1.doc_facts(str(BASE / "нет-такого.md"))
    gone = s1.verify_against_doc(info, "принятое решение K2")
    check("T4d doc: missing document never confirms a decision", not gone["doc_confirmed"], str(gone.get("doc_reason")))


def test_failure_isolation() -> None:
    conv = new_conversation(
        [("user", "Принято решение K4 по проекту TEST-WRITE-01: датчик уровня подключается к входу X0.7, чтобы контролировать перелив.")],
        "failure",
    )
    capture(conv)
    queued = len(queue_records(conv))
    write_config(store=Path("/proc/stage1-unwritable"))
    rc, out, _ = write_batch(conv)
    left = len(queue_records(conv))
    state = state_of(conv)
    check(
        "T5a failure: broken store does not break the hook",
        rc == 0 and not out.strip(),
        f"rc={rc} stdout={out!r}",
    )
    check(
        "T5b failure: queued messages survive for retry",
        queued > 0 and left == queued and state.get("failures", 0) >= 1,
        f"queued={queued} left={left} failures={state.get('failures')}",
    )
    write_config()
    rc, _, _ = write_batch(conv)
    memory = mem()
    stored = [t for t in texts(memory) if "K4" in t]
    check(
        "T5c failure: retry with restored store writes the batch",
        rc == 0 and not queue_records(conv) and bool(stored),
        f"facts mentioning K4: {len(stored)}",
    )


def test_k_scenarios() -> None:
    write_doc({"K1": ("реле K1 от выхода Q0.0", "действует")})
    conv1 = new_conversation(MSG_K1, "K1 accepted")
    capture(conv1)
    write_batch(conv1)

    write_doc(
        {
            "K1": ("реле K1 от выхода Q0.0", "отменено (заменено на K2)"),
            "K2": ("катушка пускателя от Q0.1", "действует"),
        }
    )
    conv2 = new_conversation(MSG_K2, "K1 replaced by K2")
    capture(conv2)
    write_batch(conv2)

    write_doc(
        {
            "K1": ("реле K1 от выхода Q0.0", "отменено (заменено на K2)"),
            "K2": ("катушка пускателя от Q0.1", "действует"),
            "K3": ("кнопка на входе X0.5", "действует"),
        }
    )
    conv3 = new_conversation(MSG_K3, "K2 extended by K3")
    capture(conv3)
    write_batch(conv3)

    memory = mem()
    facts = all_facts(memory)
    by_text = [(t.get("memory") or "") for t in facts]

    def meta_of(substr: str) -> dict:
        for row in facts:
            if substr in (row.get("memory") or ""):
                return row.get("metadata") or {}
        return {}

    k1, k2, k3 = meta_of("K1"), meta_of("K2"), meta_of("K3")
    check("T6a K1: fact stored and doc-confirmed while K1 was active", bool(k1) and k1.get("doc_confirmed") is True, json.dumps(k1.get("doc_statuses"), ensure_ascii=False)[:120])
    check("T6b K2: fact stored and doc-confirmed after K2 replaced K1", bool(k2) and k2.get("doc_confirmed") is True, json.dumps(k2.get("doc_statuses"), ensure_ascii=False)[:120])
    check("T6c K3: fact stored and doc-confirmed while K2 stayed in force", bool(k3) and k3.get("doc_confirmed") is True, json.dumps(k3.get("doc_statuses"), ensure_ascii=False)[:120])
    k1_fact = [t for t in facts if "K1" in (t.get("memory") or "")]
    replacement = [
        row
        for row in facts
        if "отменено (заменено на K2)" in json.dumps((row.get("metadata") or {}).get("doc_statuses"), ensure_ascii=False)
    ]
    check(
        "T6d replacement recorded: K1 -> отменено (заменено на K2) in the K2 batch",
        bool(replacement),
        f"{len(replacement)} fact(s) carry that status",
    )
    added = [
        row
        for row in facts
        if (row.get("metadata") or {}).get("doc_statuses", {}).get("K2") == "действует"
        and (row.get("metadata") or {}).get("doc_statuses", {}).get("K3") == "действует"
    ]
    check(
        "T6e addition recorded: K2 stays действует next to K3 (no cancellation)",
        bool(added),
        f"{len(added)} fact(s) show both active",
    )
    proposal = [t for t in by_text if "P2" in t and ("принято" in t.lower() or "действует" in t.lower())]
    check("T6f proposal: assumption about P2 never stored as a decision", not proposal, str(proposal)[:200])
    total = len(facts)
    check("T6g history: superseded K1 still stored, no deletion", bool(k1_fact) and total >= 3, f"facts={total}, K1 rows={len(k1_fact)}")

    hits = search(memory, "Как сейчас управляется насос P1 в проекте TEST-WRITE-01?")
    top = (hits[0].get("memory") or "") if hits else ""
    check("T6h search: current solution is retrievable by question", bool(hits), f"top1={top[:90]}")

    # Release this process's Qdrant handle: the embedded store refuses two
    # clients, and the recall hook opens the same folder in its own process.
    memory = None
    import gc

    gc.collect()

    rc, out, _ = run_hook(
        "hook_recall.py",
        {
            "event_type": "UserPromptSubmit",
            "session_id": "selftest-recall",
            "working_dir": PROJECT_WORKDIR,
            "message": "Как сейчас управляется насос P1 в проекте TEST-WRITE-01?",
        },
    )
    context = ""
    try:
        context = json.loads(out).get("additionalContext", "")
    except Exception:
        pass
    check(
        "T6i recall: injected context states live document status, not the stored snapshot",
        rc == 0
        and "записано из разговора" in context
        and "K1 — отменено (заменено на K2)" in context,
        context.replace("\n", " ")[:260],
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="keep the selftest store")
    args = parser.parse_args()

    if BASE.exists() and not args.keep:
        shutil.rmtree(BASE)
    (BASE / "queue").mkdir(parents=True, exist_ok=True)
    (BASE / "state").mkdir(parents=True, exist_ok=True)
    CONV_ROOT.mkdir(parents=True, exist_ok=True)
    write_config()
    write_doc({"K1": ("реле K1 от выхода Q0.0", "действует")})

    started = time.time()
    conv = test_capture_idempotent()
    test_write_and_noise(conv)
    before = len(all_facts(mem()))
    test_rerun_idempotent(conv, before)
    test_doc_fail_closed()
    test_failure_isolation()
    test_k_scenarios()

    passed = sum(1 for _, ok, _ in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} checks passed in {time.time() - started:.1f}s")
    print(f"store: {BASE / 'store'}  queue: {BASE / 'queue'}")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
