#!/bin/bash
# openhands-backup.sh — ежедневная резервная копия дерева OpenHands Agent на внешний диск.
#
# Отличия от прежней версии (минимальная правка, та же служба/таймер/имена/каталоги):
#   1. безопасная ротация: удаление только после чистого проверенного прогона и только
#      выше минимума хранимых копий; возраст считается от самой свежей копии уровня,
#      поэтому долгий простой не уничтожает историю; последняя проверенная копия
#      защищена явно.
#   2. пропуск копирования, если существенные данные не изменились (отпечаток),
#      при этом ежедневный таймер сохраняется; сбой определения изменений трактуется
#      как «изменения есть», а не как «изменений нет».
#   3. согласованное копирование баз SQLite (включая локальное хранилище встроенного
#      Qdrant) через штатный SQLite Backup API; исходные базы исключаются из прохода
#      tar, поэтому оригинал и его копия не попадают в один архив.
#   Плюс: код возврата tar проверяется явно и не маскируется конвейером.
#
# Контейнеры (OpenHands, Amnezia, Nextcloud) не останавливаются: съём идёт с живого дерева.

set -uo pipefail

SRC_PARENT=${OH_SRC_PARENT:-/srv}
SRC_NAME=${OH_SRC_NAME:-openhands-agent}
SRC_ROOT="$SRC_PARENT/$SRC_NAME"
MOUNT_CHECK=${OH_MOUNT_CHECK:-/mnt/amnesia-backup}
BACKUP_DIR=${OH_BACKUP_DIR:-$MOUNT_CHECK/openhands-agent}

LOG_FILE="$BACKUP_DIR/backup.log"
STATE_DIR="$BACKUP_DIR/.state"
FP_FILE="$STATE_DIR/fingerprint"
LAST_GOOD_FILE="$STATE_DIR/last-good"
RETENTION_BOOTSTRAPPED="$STATE_DIR/retention-bootstrapped"
LOCK_FILE="$STATE_DIR/lock"

DAILY_KEEP_DAYS=7
WEEKLY_KEEP_DAYS=28
DAILY_MIN_KEEP=3
WEEKLY_MIN_KEEP=2

TODAY=$(date -u +%F)
ISO_WEEK=$(date -u +%G-W%V)
DAILY_DIR="$BACKUP_DIR/daily"
WEEKLY_DIR="$BACKUP_DIR/weekly"
DAILY_FILE="$DAILY_DIR/openhands_$TODAY.tar.gz"
WEEKLY_FILE="$WEEKLY_DIR/openhands_$ISO_WEEK.tar.gz"

# Не существенные данные: воспроизводимые окружения, кэши, журнал команд Canvas,
# кэш моделей fastembed и symlink на сам диск архивов.
EXCL_DIR_NAMES="venv __pycache__ node_modules .git bash_events cache"
# Список обязан совпадать с фильтрами в python-блоке (SKIP_FILES / SKIP_SUFFIX),
# иначе отпечаток и состав архива разойдутся.
EXCL_FILE_PATTERNS="owner_lease.json *.lock *.tmp *.swp *.swo *.pyc *-journal *-wal *-shm"

log() {
    local msg
    msg="$(date -u '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$msg"
    [ -d "$BACKUP_DIR" ] && printf '%s\n' "$msg" >>"$LOG_FILE"
    return 0
}

die() { log "$*"; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0. Проверки и защита от параллельного запуска
# ---------------------------------------------------------------------------
[ -d "$SRC_ROOT" ] || die "FAIL source tree missing: $SRC_ROOT"
mountpoint -q "$MOUNT_CHECK" || die "FAIL external disk not mounted: $MOUNT_CHECK"
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR" "$STATE_DIR" || die "FAIL cannot prepare $BACKUP_DIR"

exec 9>"$LOCK_FILE"
flock -n 9 || { log "SKIP — another backup run holds the lock"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/openhands-backup.XXXXXX") || die "FAIL cannot create work dir"

# ---------------------------------------------------------------------------
# 1. Отпечаток существенных данных + согласованные копии баз SQLite
# ---------------------------------------------------------------------------
# stdout: "<fingerprint> <entries> <db_ok> <db_bad>"
# файлы: dbs-ok.list / dbs-bad.list (пути относительно SRC_ROOT)
# ненулевой код: отпечаток получить не удалось
FP_LINE=$(python3 - "$SRC_ROOT" "$WORK" "$EXCL_DIR_NAMES" "$SRC_NAME" <<'PY'
import hashlib
import os
import sqlite3
import sys

root, work, dir_names, src_name = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4]
MAGIC = b"SQLite format 3\x00"
SKIP_FILES = {"owner_lease.json"}                 # heartbeat беседы, меняется постоянно
SKIP_SUFFIX = (".lock", ".tmp", ".swp", ".swo", ".pyc", "-journal", "-wal", "-shm")
stage_root = os.path.join(work, "dbs")
entries = sqlite_ok = sqlite_bad = 0
ok_list, bad_list = [], []


def excluded(parts):
    if any(part in dir_names for part in parts[:-1]):
        return True
    for i in range(len(parts) - 1):              # <...>/store/models — кэш fastembed
        if parts[i] == "store" and parts[i + 1] == "models":
            return True
    name = parts[-1]
    # имя файла, совпадающее с исключённым каталогом, tar тоже пропускает — держим паритет
    return name in SKIP_FILES or name in dir_names or name.endswith(SKIP_SUFFIX)


def stage_db(path, rel):
    """Логический хеш (не зависит от свободных страниц) + согласованная копия базы."""
    digest = hashlib.sha256()
    out = os.path.join(stage_root, src_name, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    src = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=30.0)
    try:
        for line in src.iterdump():
            digest.update(line.encode("utf-8", "replace"))
            digest.update(b"\n")
        if os.path.exists(out):
            os.remove(out)
        dst = sqlite3.connect(out)
        try:
            src.backup(dst)                      # штатный Backup API: снимок на живой базе
        finally:
            dst.close()
    finally:
        src.close()
    chk = sqlite3.connect(out)
    try:
        verdict = chk.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        chk.close()
    if verdict != "ok":
        os.remove(out)
        raise sqlite3.DatabaseError("integrity_check=%s" % verdict)
    return "db:" + digest.hexdigest()


def file_digest(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


walk_errors = []
total = hashlib.sha256()

for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: walk_errors.append(repr(e))):
    dirnames[:] = sorted(d for d in dirnames if d not in dir_names)
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        if excluded(rel.split(os.sep)):
            continue
        try:
            st = os.lstat(path)
            if os.path.islink(path):
                kind, size = "link", 0            # tar архивирует ссылку — следим за целью
            elif not os.path.isfile(path):
                continue
            else:
                size = st.st_size
                kind = "db" if open(path, "rb").read(16) == MAGIC else "file"
        except OSError:
            continue

        if kind == "db":
            try:
                value = stage_db(path, rel)
                sqlite_ok += 1
                ok_list.append(rel)
            except Exception as exc:                                   # noqa: BLE001
                # копию снять нельзя — оригинал останется в архиве как есть
                value = "db-fail:%s" % type(exc).__name__
                sqlite_bad += 1
                bad_list.append(rel)
                sys.stderr.write("DB-STAGE-FAIL %s (%s)\n" % (rel, type(exc).__name__))
        elif kind == "link":
            value = "link:" + os.readlink(path)
        else:
            try:
                value = file_digest(path)
            except OSError as exc:
                # нечитаемый файл не должен выглядеть как «неизменённый»
                value = "err:%s" % type(exc).__name__

        entries += 1
        total.update(("%s\0%d\0%s\n" % (rel, size, value)).encode("utf-8", "replace"))

os.makedirs(stage_root, exist_ok=True)
with open(os.path.join(work, "dbs-ok.list"), "w") as fh:
    fh.write("".join(p + "\n" for p in ok_list))
with open(os.path.join(work, "dbs-bad.list"), "w") as fh:
    fh.write("".join(p + "\n" for p in bad_list))

if walk_errors:
    sys.stderr.write("WALK-ERROR %s\n" % walk_errors[0])

print("%s %d %d %d" % (total.hexdigest(), entries, sqlite_ok, sqlite_bad))
PY
)
py_rc=$?
if [ "$py_rc" -ne 0 ] || [ -z "$FP_LINE" ]; then
    log "WARN change detection failed (rc=$py_rc) — a full backup will be attempted"
    FP="detection-failed-$(date -u +%s)"
    ENTRIES=0
    DB_OK=0
    DB_BAD=0
else
    read -r FP ENTRIES DB_OK DB_BAD <<<"$FP_LINE"
fi

CLEAN=1
[ "${DB_BAD:-0}" -gt 0 ] && CLEAN=0
log "SCAN ${ENTRIES:-0} entries, ${DB_OK:-0} sqlite staged, ${DB_BAD:-0} failed, fp ${FP:0:12}"

# ---------------------------------------------------------------------------
# 2. Нужна ли новая копия
# ---------------------------------------------------------------------------
LAST_FP=$(cat "$FP_FILE" 2>/dev/null || true)
LAST_GOOD=$(cat "$LAST_GOOD_FILE" 2>/dev/null || true)

archive_ok() {   # архив существует и целиком читается
    [ -f "$1" ] && gzip -t "$1" 2>/dev/null && tar tzf "$1" >/dev/null 2>&1
}

SKIPPED=0
if [ -n "$LAST_FP" ] && [ "$FP" = "$LAST_FP" ] && [ -n "$LAST_GOOD" ] && archive_ok "$LAST_GOOD"; then
    SKIPPED=1
    log "SKIP daily — no changes since $(basename "$LAST_GOOD") (fp ${FP:0:12})"
    log "VERIFY ok $(basename "$LAST_GOOD")"
fi

# ---------------------------------------------------------------------------
# 3. Создание архива
# ---------------------------------------------------------------------------
fail_tar() {
    log "FAIL $2 rc=$1 — previous archives left untouched"
    sed -n '1,5p' "$TAR_LOG" | while IFS= read -r line; do log "  tar: $line"; done
    exit 1
}

if [ "$SKIPPED" -eq 0 ]; then
    log "START daily → $DAILY_FILE (fp ${FP:0:12})"

    EXCL_ARGS=(--exclude="backups")
    for name in $EXCL_DIR_NAMES; do EXCL_ARGS+=(--exclude="$name"); done
    EXCL_ARGS+=(--exclude="*/store/models")
    for pat in $EXCL_FILE_PATTERNS; do EXCL_ARGS+=(--exclude="$pat"); done

    # Для баз, с которых снята согласованная копия, оригинал исключается из прохода tar:
    # оригинал и его копия не должны оказаться в одном архиве.
    STAGED=()
    if [ -s "$WORK/dbs-ok.list" ]; then
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            STAGED+=("$rel")
            EXCL_ARGS+=(--exclude="$SRC_NAME/$rel"     --exclude="$SRC_NAME/$rel-journal" \
                        --exclude="$SRC_NAME/$rel-wal" --exclude="$SRC_NAME/$rel-shm")
        done <"$WORK/dbs-ok.list"
    fi

    TMP_ARCHIVE="$WORK/openhands_$TODAY.tar.gz"
    TAR_LOG="$WORK/tar.log"

    if [ "${#STAGED[@]}" -gt 0 ]; then
        # GNU tar не дописывает в сжатый архив: дерево без баз → append копий → gzip.
        # Опции обязаны идти ДО аргументов, иначе tar молча их игнорирует.
        TREE_TAR="$WORK/tree.tar"
        tar "${EXCL_ARGS[@]}" -cf "$TREE_TAR" -C "$SRC_PARENT" "$SRC_NAME" >"$TAR_LOG" 2>&1
        tar_rc=$?
        [ "$tar_rc" -ge 2 ] && fail_tar "$tar_rc" "tar"
        if [ "$tar_rc" -eq 1 ]; then
            log "WARN tar reported changes while reading (rc=1) — archive still verified"
            CLEAN=0
        fi
        tar -rf "$TREE_TAR" -C "$WORK/dbs" "$SRC_NAME" >>"$TAR_LOG" 2>&1
        tar2_rc=$?
        [ "$tar2_rc" -ne 0 ] && fail_tar "$tar2_rc" "tar --append (staged databases)"
        gzip -6 -c "$TREE_TAR" >"$TMP_ARCHIVE"
        gz_rc=$?
        [ "$gz_rc" -ne 0 ] && fail_tar "$gz_rc" "gzip"
    else
        tar "${EXCL_ARGS[@]}" -czf "$TMP_ARCHIVE" -C "$SRC_PARENT" "$SRC_NAME" >"$TAR_LOG" 2>&1
        tar_rc=$?
        [ "$tar_rc" -ge 2 ] && fail_tar "$tar_rc" "tar"
        if [ "$tar_rc" -eq 1 ]; then
            log "WARN tar reported changes while reading (rc=1) — archive still verified"
            CLEAN=0
        fi
    fi

    gzip -t "$TMP_ARCHIVE" 2>/dev/null \
        || die "FAIL gzip -t — new archive unreadable, previous archives left untouched"
    members=$(set +o pipefail; tar tzf "$TMP_ARCHIVE" 2>/dev/null | grep -v '/$' | wc -l)
    # копии баз заменяют оригиналы один к одному, поэтому число записей совпадает с ENTRIES
    expected=${ENTRIES:-0}
    if [ "${ENTRIES:-0}" -gt 0 ] && [ "$members" -ne "$expected" ]; then
        log "WARN member count $members != expected $expected — retention blocked"
        CLEAN=0
    fi
    missing=0
    for rel in "${STAGED[@]}"; do
        tar tzf "$TMP_ARCHIVE" "$SRC_NAME/$rel" >/dev/null 2>&1 || {
            log "WARN database copy missing in archive: $rel"
            missing=$((missing + 1))
        }
    done
    [ "$missing" -gt 0 ] && CLEAN=0

    # атомарная подмена: сначала копия рядом с целевым файлом, затем rename в пределах каталога
    PARTIAL="$DAILY_FILE.part"
    rm -f "$PARTIAL"
    cp -f "$TMP_ARCHIVE" "$PARTIAL" || { rm -f "$PARTIAL"; die "FAIL cannot copy archive into place"; }
    mv -f "$PARTIAL" "$DAILY_FILE" || { rm -f "$PARTIAL"; die "FAIL cannot rename archive into place"; }
    ( cd "$DAILY_DIR" && sha256sum "$(basename "$DAILY_FILE")" >"$(basename "$DAILY_FILE").sha256" ) 2>/dev/null || true
    log "OK daily $DAILY_FILE ($(du -h "$DAILY_FILE" | cut -f1))"

    printf '%s\n' "$FP" >"$FP_FILE"
    printf '%s\n' "$DAILY_FILE" >"$LAST_GOOD_FILE"

    if [ "$(date -u +%u)" = "7" ] && [ ! -f "$WEEKLY_FILE" ]; then
        if ln "$DAILY_FILE" "$WEEKLY_FILE" 2>/dev/null || cp "$DAILY_FILE" "$WEEKLY_FILE"; then
            log "OK weekly — linked from daily → $WEEKLY_FILE"
        else
            log "WARN weekly copy failed (daily archive is intact)"
        fi
    fi
else
    if [ "$(date -u +%u)" = "7" ] && [ ! -f "$WEEKLY_FILE" ] \
       && [ -n "$LAST_GOOD" ] && archive_ok "$LAST_GOOD"; then
        if ln "$LAST_GOOD" "$WEEKLY_FILE" 2>/dev/null || cp "$LAST_GOOD" "$WEEKLY_FILE"; then
            log "OK weekly — linked from $(basename "$LAST_GOOD") → $WEEKLY_FILE"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 4. Ротация: только после чистого и проверенного прогона
# ---------------------------------------------------------------------------
rotate_tier() {
    local dir="$1" keep_days="$2" min_keep="$3" tier="$4"
    local files count newest anchor cutoff remain removed f ordered
    [ -d "$dir" ] || return 0
    files=$(find "$dir" -maxdepth 1 -type f -name '*.tar.gz' | sort)
    count=$(set +o pipefail; printf '%s\n' "$files" | grep -c .)
    [ "${count:-0}" -ge 1 ] || return 0

    ordered=$(while IFS= read -r f; do
                  [ -n "$f" ] && printf '%s %s\n' "$(stat -c %Y "$f")" "$f"
              done <<<"$files" | sort -n | cut -d' ' -f2-)
    newest=$(printf '%s\n' "$ordered" | tail -1)

    # Опорная точка — эталонная проверенная копия, иначе самая свежая.
    # Возраст считается от неё, а не от «сегодня»: простой не убивает историю.
    anchor="$newest"
    if [ -n "${LAST_GOOD:-}" ] && [ -f "$LAST_GOOD" ] && [ "$(dirname "$LAST_GOOD")" = "$dir" ]; then
        anchor="$LAST_GOOD"
    fi
    cutoff=$(( $(stat -c %Y "$anchor") - keep_days * 86400 ))

    remain=$count
    removed=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$f" = "$newest" ] && continue            # самую свежую не удаляем никогда
        [ "$f" = "${LAST_GOOD:-}" ] && continue     # эталонную проверенную не удаляем
        [ "$remain" -le "$min_keep" ] && break      # минимум копий уровня сохраняется
        if [ "$(stat -c %Y "$f")" -lt "$cutoff" ]; then
            if rm -f "$f" "$f.sha256"; then
                removed=$((removed + 1))
                remain=$((remain - 1))
            fi
        fi
    done <<<"$ordered"

    [ "$removed" -gt 0 ] && log "ROTATION removed $removed $tier (anchor $(basename "$anchor"))"
    ROTATED=$((ROTATED + removed))
    return 0
}

ROTATED=0
if [ "$CLEAN" -ne 1 ]; then
    log "ROTATION skipped — run was not clean, previous archives preserved"
elif [ ! -f "$RETENTION_BOOTSTRAPPED" ]; then
    : >"$RETENTION_BOOTSTRAPPED"
    log "ROTATION skipped — first run of new retention logic, existing archives preserved"
else
    rotate_tier "$DAILY_DIR" "$DAILY_KEEP_DAYS" "$DAILY_MIN_KEEP" daily
    rotate_tier "$WEEKLY_DIR" "$WEEKLY_KEEP_DAYS" "$WEEKLY_MIN_KEEP" weekly
    [ "$ROTATED" -eq 0 ] && log "ROTATION — removed 0 daily, 0 weekly"
fi

log "DONE"
exit 0
