"""Shared primitives for the M3 stage-1 write path (capture -> batch write).

Nothing here talks to OpenHands internals: hooks are plain shell commands that
receive the HookEvent JSON on stdin, and the conversation transcript is read
from the SDK's own persistence directory (``event-*.json`` per event), which is
written by the agent server regardless of this plugin.

Scope: ``scope="global"`` writes every conversation it can attribute safely —
to the project taken from the conversation's own workspace metadata when that
workspace is a real project directory, otherwise to the general bucket. Nothing
is ever attributed to a project that cannot be derived from existing metadata,
and no document is created by this code.
"""

from __future__ import annotations

import contextlib
import fcntl
import gc
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path("/projects/memory-pilot")
STAGE1 = ROOT / "stage1"
CONFIG_PATH = Path(os.environ.get("MEMORY_STAGE1_CONFIG", STAGE1 / "config.json"))
# Queue/state/audit always live next to the active config, so a test config in a
# temp dir cannot touch the live queue.
BASE = CONFIG_PATH.parent
QUEUE_DIR = BASE / "queue"
STATE_DIR = BASE / "state"
LOG_DIR = ROOT / "logs"
AUDIT_LOG = BASE / "writes.jsonl"

EMBED_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
EMBED_DIMS = 384
MODELS = ROOT / "store" / "models"  # shared read-only fastembed cache
PROFILE = Path.home() / ".openhands" / "profiles" / "deepseek-chat.json"

SKIP_SOURCES = {"hook", "environment", "user_rejected", "agent_rejected"}
DECISION_RE = re.compile(r"\b[KК]\s?\d+\b")
DOC_DATE_RE = re.compile(r"Дата\s+пересмотра\s*:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})")
SECTION_RE = re.compile(r"^#{2,3}\s*([KК]\s?\d+)\b(.*)$", re.MULTILINE)
STATUS_RE = re.compile(r"Статус\s*:\s*(.+)", re.IGNORECASE)


# ---------------------------------------------------------------- logging ----

def log(name: str, message: str) -> None:
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with (LOG_DIR / f"stage1_{name}.log").open("a", encoding="utf-8") as fh:
            stamp = time.strftime("%Y-%m-%d %H:%M:%S")
            fh.write(f"{stamp} {message}\n")
    except Exception:
        pass


def protect_stdout() -> Any:
    """Keep a private handle on real stdout and point fd 1 at stderr.

    A hook's stdout is parsed as JSON by OpenHands; anything else printed there
    would be a protocol error. Library chatter (mem0, fastembed, urllib) must
    therefore never reach fd 1.
    """
    real = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return real


# ----------------------------------------------------------------- config ----

def load_config() -> dict[str, Any]:
    with CONFIG_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)


def enabled(cfg: dict[str, Any]) -> bool:
    return bool(cfg.get("enabled"))


def general_id(cfg: dict[str, Any]) -> str:
    return str(cfg.get("general_project_id") or "general")


def global_scope(cfg: dict[str, Any]) -> bool:
    return str(cfg.get("scope") or "global") == "global"


def _under(path: Path, root: str) -> bool:
    try:
        path.relative_to(Path(root).expanduser().resolve())
        return True
    except Exception:
        return False


def _looks_like_hash(name: str) -> bool:
    return bool(re.fullmatch(r"[0-9a-f]{6,}", name))


def find_doc(cfg: dict[str, Any], project_path: Path) -> str | None:
    """Existing decision document of a project; nothing is ever created."""
    for relative in cfg.get("doc_candidates") or []:
        candidate = project_path / relative
        try:
            if candidate.is_file():
                return str(candidate)
        except Exception:
            continue
    return None


def explicit_spec(cfg: dict[str, Any], path: Path) -> dict[str, Any] | None:
    for key, spec in (cfg.get("projects") or {}).items():
        try:
            if Path(key).expanduser().resolve() == path:
                return spec
        except Exception:
            continue
    return None


def session_working_dir(cfg: dict[str, Any], session_id: str | None) -> str | None:
    """Workspace recorded by the agent server for this conversation."""
    if not session_id:
        return None
    root = Path(cfg.get("conversations_root", Path.home() / ".openhands/agent-canvas/conversations"))
    for name in (session_id.replace("-", ""), session_id):
        try:
            meta = json.loads((root / name / "meta.json").read_text(encoding="utf-8"))
        except Exception:
            continue
        working_dir = (meta.get("workspace") or {}).get("working_dir") or meta.get("working_dir")
        if working_dir:
            return working_dir
    return None


def resolve_context(
    cfg: dict[str, Any],
    working_dir: str | None = None,
    session_id: str | None = None,
) -> dict[str, Any]:
    """Decide which project a conversation belongs to, from existing metadata only.

    Order of precedence: an explicit entry in ``projects``, then a real directory
    under one of ``project_roots`` (identity = directory name), otherwise the
    general bucket. Ephemeral workspaces (per-canvas hash dirs under /tmp or the
    container's scratch space) are never turned into projects.
    """
    ctx: dict[str, Any] = {
        "project_id": None,
        "project_path": None,
        "canonical_doc": None,
        "explicit": False,
        "write": True,
        "recall": True,
    }
    path_text = working_dir or session_working_dir(cfg, session_id)
    if not path_text:
        return ctx
    try:
        path = Path(path_text).expanduser().resolve()
    except Exception:
        return ctx

    spec = explicit_spec(cfg, path)
    if spec is not None:
        ctx.update(
            project_id=spec.get("project_id") or path.name,
            project_path=str(path),
            canonical_doc=spec.get("canonical_doc") or find_doc(cfg, path),
            explicit=True,
            write=bool(spec.get("write", True)),
            recall=bool(spec.get("recall", True)),
        )
        return ctx

    if str(cfg.get("scope") or "global") != "global":
        return ctx
    if not path.is_dir():
        return ctx
    if any(_under(path, root) for root in cfg.get("ephemeral_roots") or []):
        return ctx
    if any(_looks_like_hash(part) for part in path.parts[-2:]):
        return ctx
    if not any(_under(path, root) for root in cfg.get("project_roots") or []):
        return ctx
    ctx.update(
        project_id=path.name,
        project_path=str(path),
        canonical_doc=find_doc(cfg, path),
    )
    return ctx


# ------------------------------------------------------------- filesystem ----

def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


class queue_lock:
    """Non-blocking lock; a busy queue is simply retried on the next event."""

    def __init__(self, conv_hex: str) -> None:
        self.path = QUEUE_DIR / f"{conv_hex}.lock"
        self.fh = None

    def __enter__(self) -> bool:
        try:
            QUEUE_DIR.mkdir(parents=True, exist_ok=True)
            self.fh = self.path.open("w")
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except Exception:
            if self.fh:
                self.fh.close()
                self.fh = None
            return False

    def __exit__(self, *exc: Any) -> None:
        if self.fh:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_UN)
            finally:
                self.fh.close()
                self.fh = None


@contextlib.contextmanager
def store_lock(store: str | Path, wait: float = 0.0):
    """Serialise access to the embedded Qdrant folder across hook processes.

    A local Qdrant store refuses to open twice ("already accessed by another
    instance"), so a recall during a write would otherwise drop the fragments
    and log an error. Callers that must not wait (the read hook) pass a small
    ``wait`` and skip the store when it is busy.
    """
    path = Path(store) / "stage1.lock"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = path.open("w")
    except Exception:
        # Cannot even place a lock file: do not pretend the store is busy, let
        # the caller hit the real error and record it.
        yield True
        return
    acquired = False
    deadline = time.time() + max(0.0, wait)
    try:
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                if time.time() >= deadline:
                    break
                time.sleep(0.2)
            except Exception:
                break
        yield acquired
    finally:
        if acquired:
            try:
                fcntl.flock(handle, fcntl.LOCK_UN)
            except Exception:
                pass
        handle.close()


def queue_path(conv_hex: str) -> Path:
    return QUEUE_DIR / f"{conv_hex}.jsonl"


def state_path(conv_hex: str) -> Path:
    return STATE_DIR / f"{conv_hex}.json"


def read_state(conv_hex: str) -> dict[str, Any]:
    try:
        with state_path(conv_hex).open(encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {"last_index": -1, "batches": [], "failures": 0}


def write_state(conv_hex: str, state: dict[str, Any]) -> None:
    _atomic_write(state_path(conv_hex), json.dumps(state, ensure_ascii=False, indent=1))


def read_queue(conv_hex: str) -> list[dict[str, Any]]:
    path = queue_path(conv_hex)
    if not path.exists():
        return []
    out: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                continue
    return out


def append_queue(conv_hex: str, records: list[dict[str, Any]]) -> None:
    if not records:
        return
    path = queue_path(conv_hex)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def rewrite_queue(conv_hex: str, keep: list[dict[str, Any]]) -> None:
    if keep:
        _atomic_write(
            queue_path(conv_hex),
            "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in keep),
        )
    else:
        try:
            queue_path(conv_hex).unlink()
        except FileNotFoundError:
            pass


def audit(entry: dict[str, Any]) -> None:
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        with AUDIT_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


# ------------------------------------------------------------- transcript ----

def events_dir(cfg: dict[str, Any], session_id: str) -> Path | None:
    root = Path(cfg.get("conversations_root", Path.home() / ".openhands/agent-canvas/conversations"))
    for name in (session_id.replace("-", ""), session_id):
        candidate = root / name / "events"
        if candidate.is_dir():
            return candidate
    return None


def _text_of(message: dict[str, Any]) -> str:
    parts = []
    for content in message.get("content") or []:
        if isinstance(content, dict) and content.get("type") == "text":
            parts.append(content.get("text") or "")
    return "\n".join(p for p in parts if p).strip()


def message_records(events_dir_path: Path, after_index: int, limit_chars: int) -> tuple[list[dict[str, Any]], int]:
    """Return new user/assistant messages and the highest event index seen."""
    records: list[dict[str, Any]] = []
    highest = after_index
    files = []
    for path in events_dir_path.glob("event-*.json"):
        match = re.match(r"event-(\d+)-", path.name)
        if not match:
            continue
        index = int(match.group(1))
        if index <= after_index:
            continue
        files.append((index, path))
    files.sort()
    for index, path in files:
        highest = max(highest, index)
        try:
            with path.open(encoding="utf-8") as fh:
                event = json.load(fh)
        except Exception:
            continue
        if event.get("kind") != "MessageEvent":
            continue
        if (event.get("source") or "") in SKIP_SOURCES:
            continue
        llm_message = event.get("llm_message") or {}
        role = llm_message.get("role")
        if role not in ("user", "assistant"):
            continue
        text = _text_of(llm_message)
        if len(text) < 2:
            continue
        if len(text) > limit_chars:
            text = text[:limit_chars] + "…"
        records.append(
            {
                "event_index": index,
                "event_id": event.get("id"),
                "role": role,
                "ts": event.get("timestamp"),
                "text": text,
            }
        )
    return records, highest


# ------------------------------------------------------------------- mem0 ----

def deepseek_credentials() -> tuple[str, str, str]:
    from base64 import b64encode

    try:
        from cryptography.fernet import Fernet
    except ModuleNotFoundError:  # cryptography ships with the system interpreter
        sys.path.append("/usr/local/lib/python3.13/site-packages")
        from cryptography.fernet import Fernet

    profile = json.loads(PROFILE.read_text(encoding="utf-8"))
    secret = os.environ["OH_SECRET_KEY"].encode()
    key = Fernet(b64encode(hashlib.sha256(secret).digest())).decrypt(profile["api_key"].encode()).decode()
    return key, profile["base_url"], profile["model"].split("/")[-1]


def build_memory(cfg: dict[str, Any], *, with_llm: bool = True):
    """Open the stage-1 store. The LLM is only configured for infer=True calls."""
    os.environ.setdefault("MEM0_TELEMETRY", "False")
    os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS))

    from mem0 import Memory
    from mem0.configs.base import MemoryConfig
    from mem0.embeddings.configs import EmbedderConfig
    from mem0.llms.configs import LlmConfig
    from mem0.vector_stores.configs import VectorStoreConfig

    store = Path(cfg.get("store", STAGE1 / "store"))
    key, base_url, model = deepseek_credentials()
    llm = LlmConfig(
        provider="deepseek",
        config={
            "api_key": key if with_llm else "STAGE1-READ-ONLY",
            "model": model,
            "deepseek_base_url": base_url,
            "temperature": 0.1,
            "max_tokens": 2000,
        },
    )
    return Memory(
        config=MemoryConfig(
            vector_store=VectorStoreConfig(
                provider="qdrant",
                config={
                    "path": str(store / "qdrant_db"),
                    "collection_name": cfg.get("collection", "stage1_memories"),
                    "embedding_model_dims": EMBED_DIMS,
                    "on_disk": True,
                },
            ),
            embedder=EmbedderConfig(
                provider="fastembed",
                config={"model": EMBED_MODEL, "embedding_dims": EMBED_DIMS},
            ),
            llm=llm,
            history_db_path=str(store / "history.db"),
            custom_instructions=cfg.get("custom_instructions"),
        )
    )


def release_store(cache: dict[str, Any] | None = None) -> None:
    """Drop Memory/Qdrant references so the folder lock is actually released."""
    if cache is not None:
        cache.clear()
    gc.collect()


# ---------------------------------------------------------- canonical doc ----

def doc_facts(path: str | None) -> dict[str, Any]:
    """Parse the canonical decision document into {decision_id: status} + meta."""
    info: dict[str, Any] = {"path": path, "ok": False, "date": None, "sha256": None, "decisions": {}}
    if not path:
        # A project without a decision document is a normal case in global mode:
        # facts are still stored, they are just not doc-confirmed.
        info["reason"] = "no_project_document"
        return info
    try:
        raw = Path(path).read_bytes()
    except Exception as exc:
        info["reason"] = f"unreadable: {type(exc).__name__}"
        return info
    text = raw.decode("utf-8", "replace")
    info["ok"] = True
    info["sha256"] = hashlib.sha256(raw).hexdigest()[:12]
    match = DOC_DATE_RE.search(text)
    info["date"] = match.group(1) if match else None
    for section in SECTION_RE.finditer(text):
        decision = re.sub(r"\s+", "", section.group(1)).replace("К", "K")
        tail = text[section.end() : section.end() + 400]
        status = STATUS_RE.search(tail)
        info["decisions"][decision] = (status.group(1).strip() if status else "статус не указан")
    if not info["decisions"]:
        info["reason"] = "no_decisions_parsed"
    return info


def verify_against_doc(info: dict[str, Any], fact_text: str) -> dict[str, Any]:
    """A decision is doc-confirmed only if the doc names it and dates itself."""
    ids = sorted({re.sub(r"\s+", "", m).replace("К", "K") for m in DECISION_RE.findall(fact_text)})
    if not info.get("ok"):
        return {"doc_confirmed": False, "doc_reason": info.get("reason", "doc_unavailable")}
    if not info.get("date"):
        return {"doc_confirmed": False, "doc_reason": "doc_has_no_revision_date"}
    if not ids:
        return {"doc_confirmed": False, "doc_reason": "no_decision_id_in_fact"}
    missing = [i for i in ids if i not in info["decisions"]]
    if missing:
        return {"doc_confirmed": False, "doc_reason": "not_in_doc:" + ",".join(missing)}
    return {
        "doc_confirmed": True,
        "doc_reason": "listed_in_doc",
        "doc_ref": f"{info['path']} · дата {info['date']} · sha256 {info['sha256']}",
        "doc_statuses": {i: info["decisions"][i] for i in ids},
    }
