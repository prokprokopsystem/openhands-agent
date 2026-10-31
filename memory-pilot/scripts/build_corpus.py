"""Build the M2 test corpus: two projects, small anonymised records.

Sources are public/safe project documents. Internal IP addresses are masked;
no secrets, tokens, keys or personal data are copied (verified by scan_secrets).
Output: corpus/<project>/*.txt (anonymised copies) and manifests/corpus.json.
"""

import hashlib
import json
import re
import subprocess
from pathlib import Path

CORPUS = Path("/projects/memory-pilot/corpus")
MANIFESTS = Path("/projects/memory-pilot/manifests")

SOURCES = [
    ("openhands-agent", Path("/tmp/oha"), "docs/Архитектура.md"),
    ("openhands-agent", Path("/tmp/oha"), "docs/01-requirements.md"),
    ("openhands-agent", Path("/tmp/oha"), "docs/02-architecture-and-roadmap.md"),
    ("openhands-agent", Path("/tmp/oha"), "docs/План Этапа 4B — Egress.md"),
    ("openhands-agent", Path("/tmp/oha"), "docs/План Этапа 5B — Healthcheck.md"),
    ("openhands-agent", Path("/tmp/oha"), "AGENTS.md"),
    ("02_door", Path("/tmp/_m2_stage/02door"), "README.md"),
    ("02_door", Path("/tmp/_m2_stage/02door"), "docs/tech_spec.txt"),
    ("02_door", Path("/tmp/_m2_stage/02door"), "docs/fsm.md"),
    ("02_door", Path("/tmp/_m2_stage/02door"), "src/main.cpp"),
]

IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
MIN_CHARS, MAX_CHARS = 180, 900


def mask(text: str) -> str:
    return IP_RE.sub("<IP>", text)


def file_date(repo: Path, rel: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "log", "-1", "--format=%cs", "--", rel],
            capture_output=True, text=True, timeout=20,
        ).stdout.strip()
        return out or "unknown"
    except Exception:
        return "unknown"


def chunks(text: str) -> list[tuple[str, str]]:
    """Split on markdown headings / numbered sections; small pieces get merged."""
    lines = text.splitlines()
    blocks, cur, head = [], [], ""
    for ln in lines:
        is_head = re.match(r"^#{1,4}\s+\S", ln) or re.match(r"^\d+\.\s+\S", ln)
        if is_head and sum(len(x) + 1 for x in cur) > MIN_CHARS:
            blocks.append((head, "\n".join(cur).strip()))
            cur, head = [ln], ln.lstrip("# ").strip()
        else:
            if is_head and not head:
                head = ln.lstrip("# ").strip()
            cur.append(ln)
    if cur:
        blocks.append((head, "\n".join(cur).strip()))

    out, buf, buf_head = [], [], ""
    for h, b in blocks:
        if not b:
            continue
        if len(b) > MAX_CHARS:
            if buf:
                out.append((buf_head, "\n".join(buf).strip()))
                buf, buf_head = [], ""
            out.append((h, b[:MAX_CHARS]))
            continue
        buf.append(b)
        buf_head = buf_head or h
        if sum(len(x) + 1 for x in buf) >= MIN_CHARS:
            out.append((buf_head, "\n".join(buf).strip()))
            buf, buf_head = [], ""
    if buf:
        out.append((buf_head, "\n".join(buf).strip()))
    return [(h, b) for h, b in out if len(b) >= 60]


PER_PROJECT_LIMIT = 14


def select_even(records: list[dict], limit: int) -> list[dict]:
    """Round-robin over source files so every file is represented."""
    by_file: dict[str, list[dict]] = {}
    for r in records:
        by_file.setdefault(r["source_path"], []).append(r)
    picked, idx = [], 0
    while len(picked) < limit:
        added = False
        for path in sorted(by_file):
            seq = by_file[path]
            if idx < len(seq) and len(picked) < limit:
                picked.append(seq[idx])
                added = True
        if not added:
            break
        idx += 1
    return picked


def main() -> None:
    records = []
    for project, repo, rel in SOURCES:
        src = repo / rel
        raw = src.read_text(encoding="utf-8", errors="replace")
        digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
        date = file_date(repo, rel)
        safe = mask(raw)

        outdir = CORPUS / project
        outdir.mkdir(parents=True, exist_ok=True)
        copy_name = rel.replace("/", "__")
        (outdir / copy_name).write_text(safe, encoding="utf-8")

        for i, (head, body) in enumerate(chunks(safe)):
            records.append({
                "project_id": project,
                "source_path": rel,
                "source_copy": str(outdir / copy_name),
                "sha256": digest,
                "date": date,
                "section": head or f"part-{i}",
                "text": body,
            })

    MANIFESTS.mkdir(parents=True, exist_ok=True)
    selected = []
    for project in sorted({r["project_id"] for r in records}):
        selected += select_even([r for r in records if r["project_id"] == project], PER_PROJECT_LIMIT)
    records = selected
    (MANIFESTS / "corpus.json").write_text(
        json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    per_project: dict[str, int] = {}
    for r in records:
        per_project[r["project_id"]] = per_project.get(r["project_id"], 0) + 1
    print(f"records total: {len(records)}")
    for p, n in sorted(per_project.items()):
        print(f"  {p:18} {n}")
    sizes = [len(r["text"]) for r in records]
    print(f"chunk chars: min={min(sizes)} max={max(sizes)} avg={sum(sizes)//len(sizes)}")
    print(f"total corpus chars: {sum(sizes)}")


if __name__ == "__main__":
    main()
