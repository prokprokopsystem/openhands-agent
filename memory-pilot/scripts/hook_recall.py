"""UserPromptSubmit hook: inject relevant long-term memories into the chat (M3 read stage).

OpenHands runs this as a shell hook with the HookEvent JSON on stdin and parses
stdout as JSON; `additionalContext` is appended to the user message. Only that
one JSON object may reach stdout — everything diagnostic goes to the log file.

The search is local (fastembed + embedded Qdrant): no LLM, no network egress.
Any failure exits 0 with no output, so a broken index can never block a chat.
"""

import json
import os
import re
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

LOG = SCRIPTS.parent / "logs" / "hook_recall.log"
# Ingest-time owner of the records (see scripts/ingest.py).
AGENT_ID = "m2-pilot"

TOP_K = 8
MAX_FRAGMENTS = 4
FRAGMENT_CHARS = 300
TOTAL_CHARS = 1400
MIN_QUERY_CHARS = 3

# OpenHands parses stdout as JSON, so nothing but the final object may land
# there. Keep a private handle on the real stdout and point fd 1 at stderr, so
# any library chatter (mem0/fastembed/spaCy warnings) is harmless by design.
_OUT = os.fdopen(os.dup(1), "w", encoding="utf-8")
os.dup2(2, 1)
sys.stdout = sys.stderr


def log(message: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")
    except Exception:
        pass


def emit(text: str) -> None:
    _OUT.write(json.dumps({"additionalContext": text}, ensure_ascii=False))
    _OUT.flush()


def degraded_notice(session_id: str | None, reason: str) -> None:
    """Tell the model once per session that memory is unavailable, then stay quiet."""
    marker = LOG.parent / f"degraded-{session_id or 'unknown'}.flag"
    try:
        if marker.exists():
            return
        marker.touch()
    except Exception:
        return
    emit(
        "[Долговременная память Mem0 недоступна — отвечай по текущему контексту "
        f"и не утверждай, что помнишь прошлые беседы. Причина: {reason[:120]}]"
    )


def fragments(query: str) -> list[str]:
    import memcfg

    # Qdrant local mode happily creates an empty store at a missing path, which
    # would look like "no memories" instead of an outage. Fail loudly instead.
    if not (memcfg.STORE / "qdrant_db").is_dir():
        raise RuntimeError(f"store missing: {memcfg.STORE / 'qdrant_db'}")

    mem = memcfg.memory()
    names = [c.name for c in mem.vector_store.list_cols().collections]
    if memcfg.COLLECTION not in names:
        raise RuntimeError(f"collection {memcfg.COLLECTION!r} missing")
    count = mem.vector_store.client.count(memcfg.COLLECTION, exact=False).count
    if not count:
        raise RuntimeError(f"collection {memcfg.COLLECTION!r} is empty")

    result = mem.search(query, top_k=TOP_K, filters={"agent_id": AGENT_ID})

    out: list[str] = []
    seen: set[tuple[str, str]] = set()
    for hit in result.get("results", []):
        meta = hit.get("metadata") or {}
        if meta.get("superseded_by"):
            continue
        key = (meta.get("project_id", "?"), f"{meta.get('source_path')}#{meta.get('section')}")
        if key in seen:
            continue
        seen.add(key)

        body = " ".join((hit.get("memory") or "").split())
        if len(body) > FRAGMENT_CHARS:
            body = body[:FRAGMENT_CHARS].rsplit(" ", 1)[0] + "…"
        out.append(
            f"- {meta.get('project_id', '?')} · {meta.get('source_path', '?')}"
            f" · §{meta.get('section', '?')}"
            f" · дата {meta.get('doc_date', '?')}\n  {body}"
        )
        if len(out) >= MAX_FRAGMENTS:
            break
    return out


def stage1_verdict(info: dict, ids: list[str], general: bool) -> str:
    """Describe the live status of the decisions named in a stored fact."""
    if general:
        return "общий факт, вне проекта — документально не подтверждается"
    if info.get("reason") == "no_project_document":
        return "у проекта нет канонического документа — актуальность не подтверждена"
    if not info.get("ok"):
        return "документ недоступен — актуальность не подтверждена"
    if not ids:
        return f"документ {info.get('date') or '?'} — решения не названы"
    parts = [f"{i} — {info['decisions'].get(i, 'в документе нет')}" for i in ids]
    return f"документ {info.get('date') or '?'}: " + "; ".join(parts)


def stage1_fragments(query: str, working_dir: str | None, session_id: str | None = None) -> list[str]:
    """Facts written automatically (M3 stage-1 write path), project first.

    Kept separate from the corpus search: a missing or broken stage-1 store must
    not be reported as "memory unavailable". In global mode a project chat sees
    its own project facts plus generally useful facts; a chat without a project
    sees only the general bucket, so nothing is borrowed from a random project.
    """
    import stage1_common as s1

    cfg = s1.load_config()
    if not s1.enabled(cfg):
        return []
    ctx = s1.resolve_context(cfg, working_dir, session_id)
    if not ctx.get("recall", True):
        return []
    if not s1.global_scope(cfg) and not ctx.get("explicit"):
        return []

    general = s1.general_id(cfg)
    targets: list[str] = []
    if ctx.get("project_id"):
        targets.append(ctx["project_id"])
    if s1.global_scope(cfg) and general not in targets:
        targets.append(general)
    if not targets:
        return []

    with s1.store_lock(cfg["store"], wait=3.0) as got:
        if not got:
            log("stage1 store busy, fragments skipped")
            return []
        mem = s1.build_memory(cfg, with_llm=False)
        hits: list[tuple[str, dict]] = []
        for project_id in targets:
            try:
                found = mem.search(
                    query,
                    top_k=4,
                    filters={"agent_id": cfg.get("agent_id", "stage1-write"), "project_id": project_id},
                )
            except Exception as exc:
                log(f"stage1 search for {project_id} failed: {type(exc).__name__}: {exc}")
                continue
            hits.extend((project_id, hit) for hit in found.get("results") or [])
        mem = None
        s1.release_store()
    if not hits:
        return []

    # Current status is taken from the document itself at read time: a fact
    # stored yesterday may describe a decision the document has since replaced.
    info = s1.doc_facts(ctx.get("canonical_doc"))
    out: list[str] = []
    general_used = 0
    for project_id, hit in hits:
        meta = hit.get("metadata") or {}
        is_general = not meta.get("project_path")
        if is_general and general_used >= 1:
            continue
        body = " ".join((hit.get("memory") or "").split())
        if len(body) > FRAGMENT_CHARS:
            body = body[:FRAGMENT_CHARS].rsplit(" ", 1)[0] + "…"
        conv = str(meta.get("source_conversation") or "?")
        ids = sorted({re.sub(r"\s+", "", m).replace("К", "K") for m in s1.DECISION_RE.findall(body)})
        verdict = stage1_verdict(info, ids, is_general)
        label = meta.get("project_id") or project_id
        out.append(
            f"- {label} · записано из разговора {conv[:8]}"
            f" · {meta.get('observation_date', '?')} · {verdict}\n  {body}"
        )
        if is_general:
            general_used += 1
        if len(out) >= 3:
            break
    return out


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except Exception as exc:
        log(f"bad stdin: {exc}")
        return 0

    query = (event.get("message") or "").strip()
    if len(query) < MIN_QUERY_CHARS:
        return 0
    session_id = event.get("session_id")

    started = time.time()
    degraded: str | None = None
    try:
        parts = stage1_fragments(query[:1000], event.get("working_dir"), session_id)
    except Exception as exc:
        log(f"stage1 search failed: {type(exc).__name__}: {exc}")
        parts = []
    try:
        parts += fragments(query[:1000])
    except Exception as exc:
        log(f"search failed: {type(exc).__name__}: {exc}")
        degraded = f"{type(exc).__name__}: {exc}"
    elapsed = time.time() - started

    if not parts:
        if degraded:
            degraded_notice(session_id, degraded)
        else:
            log(f"no hits ({elapsed:.2f}s): {query[:60]!r}")
        return 0

    def render(items: list[str]) -> str:
        return (
            f"[Долговременная память Mem0 — локальный поиск, {len(items)} фрагм., "
            f"{elapsed:.1f}s]\n"
            + "\n".join(items)
            + "\n[Источник указан в каждой строке. Это подборка, а не полный ответ: "
            "если нужного нет — скажи и поищи иначе.]"
        )

    # Drop whole fragments instead of cutting one mid-sentence.
    kept: list[str] = []
    for part in parts:
        if len(render(kept + [part])) > TOTAL_CHARS:
            break
        kept.append(part)
    if not kept:
        return 0

    text = render(kept)
    if degraded:
        # Corpus search failed but stage-1 facts are usable: say so instead of
        # presenting a partial selection as the whole memory.
        text += (
            "\n[Часть памяти недоступна (поиск по корпусу не выполнен): "
            f"{degraded[:120]} — подборка неполная.]"
        )
    log(f"{len(kept)} hits ({elapsed:.2f}s): {query[:60]!r}")
    emit(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
