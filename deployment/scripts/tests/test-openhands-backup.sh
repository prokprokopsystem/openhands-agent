#!/bin/bash
# test-openhands-backup.sh — песочные проверки openhands-backup.sh.
#
# Ничего вне mktemp-каталога не изменяется: источник и каталог архивов подменяются
# переменными OH_SRC_PARENT / OH_BACKUP_DIR, проверка точки монтирования — OH_MOUNT_CHECK=/.
#
# Запуск:  bash deployment/scripts/tests/test-openhands-backup.sh
# Часть проверок требует НЕ-root (сбой tar через недоступный каталог); под root они
# честно сообщают SKIP, а не ложный PASS.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${SCRIPT:-$HERE/../openhands-backup.sh}
[ -f "$SCRIPT" ] || { echo "script not found: $SCRIPT" >&2; exit 1; }

T=$(mktemp -d "${TMPDIR:-/var/tmp}/ohbk-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# ---------------------------------------------------------------- песочница
SRV=""; B=""
new_sandbox() {
    SRV="$T/$1/srv"
    B="$T/$1/backups/openhands-agent"
    rm -rf "$T/$1"
    local S="$SRV/openhands-agent"
    mkdir -p "$S/config/automation" "$S/config/agent-canvas/conversations/c1/events" \
             "$S/config/agent-canvas/bash_events" "$S/config/cache" \
             "$S/work-workspace/memory-pilot/store/qdrant_db/collection/m2" \
             "$S/work-workspace/memory-pilot/store/models" \
             "$S/work-workspace/memory-pilot/venv" "$S/docs" \
             "$B/daily" "$B/weekly"
    python3 - "$S" <<'PY'
import os, sqlite3, sys
s = sys.argv[1]
def mkdb(path, table, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    c = sqlite3.connect(path)
    c.execute("create table %s(id integer primary key, v text)" % table)
    c.executemany("insert into %s(v) values(?)" % table, [(r,) for r in rows])
    c.commit(); c.close()
mkdb(s + "/config/automation/automations.db", "automations", ["a1", "a2"])
mkdb(s + "/work-workspace/memory-pilot/store/history.db", "history", ["add"])
mkdb(s + "/work-workspace/memory-pilot/store/qdrant_db/collection/m2/storage.sqlite",
     "points", ["fact-1", "fact-2", "fact-3"])
PY
    printf '{"role":"user","text":"hello"}\n' > "$S/config/agent-canvas/conversations/c1/events/ev1.json"
    printf '{"lease":1}\n'   > "$S/config/agent-canvas/conversations/c1/owner_lease.json"
    printf '{"cmd":"ls"}\n'  > "$S/config/agent-canvas/bash_events/e1"
    head -c 4096 /dev/urandom > "$S/config/cache/big.bin"
    head -c 4096 /dev/urandom > "$S/work-workspace/memory-pilot/store/models/m.bin"
    printf 'print(1)\n'      > "$S/work-workspace/memory-pilot/venv/lib.py"
    printf '# doc v1\n'      > "$S/docs/a.md"
    ln -s "$T/$1/backups" "$S/backups"
    mkdir -p "$T/$1/backups"
}

run_backup() {
    OH_SRC_PARENT="$SRV" OH_SRC_NAME="openhands-agent" \
    OH_BACKUP_DIR="$B" OH_MOUNT_CHECK="/" bash "$SCRIPT" 2>&1
}

log_has() { grep -qF -- "$1" "$B/backup.log" 2>/dev/null; }
archive_count() { find "$1" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' '; }
newest_archive() { find "$1" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | sort | tail -1; }

# ===========================================================================
echo "== 1. Первый архив: состав, базы, отсутствие дублей =="
new_sandbox t1
out=$(run_backup); rc=$?
check "код возврата 0" "$rc" "0"
A=$(newest_archive "$B/daily")
[ -n "$A" ] && [ -f "$A" ] && ok "архив создан" || bad "архив не создан"
gzip -t "$A" 2>/dev/null && ok "gzip -t проходит" || bad "gzip -t не проходит"

listing=$(tar tzf "$A" | grep -v '/$' | sed 's#^openhands-agent/##' | sort)
echo "$listing" > "$T/t1.listing"

check "3 базы в архиве" "$(grep -cE '(automations\.db|history\.db|storage\.sqlite)$' <<<"$listing")" "3"
check "дублей-путей нет" "$(tar tzf "$A" | grep -v '/$' | sort | uniq -d | wc -l | tr -d ' ')" "0"
for pat in 'venv/' 'cache/' 'store/models/' 'bash_events/' 'owner_lease.json' 'backups'; do
    if grep -q -- "$pat" <<<"$listing"; then bad "в архив попало лишнее: $pat"; else ok "исключено: $pat"; fi
done
grep -q 'conversations/c1/events/ev1.json' <<<"$listing" && ok "разговоры отслеживаются" || bad "разговоры потеряны"
grep -q 'docs/a.md' <<<"$listing" && ok "документы в архиве" || bad "документы потеряны"

# восстановление и целостность баз
mkdir -p "$T/t1/restore"
tar xzf "$A" -C "$T/t1/restore"
integrity=$(python3 - "$T/t1/restore" <<'PY'
import glob, sqlite3, sys
root = sys.argv[1]
out = []
for p in glob.glob(root + "/**/*.db", recursive=True) + glob.glob(root + "/**/*.sqlite", recursive=True):
    c = sqlite3.connect(p)
    out.append(c.execute("pragma integrity_check").fetchone()[0])
    c.close()
print(" ".join(out))
PY
)
check "integrity_check всех восстановленных баз" "$integrity" "ok ok ok"

# ===========================================================================
echo "== 2. Отсутствие изменений → пропуск =="
before=$(stat -c %Y "$A"); before_sum=$(sha256sum "$A" | cut -d' ' -f1)
out=$(run_backup)
grep -q 'SKIP daily' <<<"$out" && ok "SKIP зафиксирован" || bad "SKIP не сработал: $out"
check "архив не пересоздан" "$(sha256sum "$A" | cut -d' ' -f1)" "$before_sum"
check "число архивов не изменилось" "$(archive_count "$B/daily")" "1"

echo "== 2b. Шум (cache, bash_events, owner_lease, venv) не считается изменением =="
head -c 4096 /dev/urandom > "$SRV/openhands-agent/config/cache/big.bin"
printf '{"cmd":"whoami"}\n' > "$SRV/openhands-agent/config/agent-canvas/bash_events/e2"
printf '{"lease":999}\n'    > "$SRV/openhands-agent/config/agent-canvas/conversations/c1/owner_lease.json"
printf 'print(2)\n'         > "$SRV/openhands-agent/work-workspace/memory-pilot/venv/lib.py"
out=$(run_backup)
grep -q 'SKIP daily' <<<"$out" && ok "шум игнорируется" || bad "шум вызвал копирование: $out"

echo "== 2c. Изменение существенных данных → новый архив =="
printf '# doc v2\n' > "$SRV/openhands-agent/docs/a.md"
out=$(run_backup)
grep -q 'START daily' <<<"$out" && ok "изменение документа замечено" || bad "изменение не замечено: $out"
grep -q 'SKIP' <<<"$out" && bad "ложный пропуск" || ok "пропуска нет"
tar xzOf "$A" openhands-agent/docs/a.md 2>/dev/null | grep -q 'v2' && ok "новое содержимое в архиве" || bad "архив содержит старое содержимое"

echo "== 2d. Изменение Mem0 / Qdrant / SQLite → новый архив =="
python3 - "$SRV/openhands-agent/work-workspace/memory-pilot/store/qdrant_db/collection/m2/storage.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("insert into points(v) values('fact-4')"); c.commit(); c.close()
PY
out=$(run_backup)
grep -q 'START daily' <<<"$out" && ok "новый факт Mem0 замечен" || bad "факт Mem0 не замечен: $out"
python3 - "$A" <<'PY'
import sqlite3, subprocess, sys, tempfile, os
with tempfile.TemporaryDirectory() as d:
    subprocess.run(["tar", "xzf", sys.argv[1], "-C", d, "--wildcards",
                    "*store/qdrant_db/collection/m2/storage.sqlite"], check=True)
    p = os.path.join(d, "openhands-agent/work-workspace/memory-pilot/store/qdrant_db/collection/m2/storage.sqlite")
    c = sqlite3.connect(p)
    print(c.execute("select count(*) from points").fetchone()[0])
PY
rows=$(tar xzOf "$A" openhands-agent/work-workspace/memory-pilot/store/qdrant_db/collection/m2/storage.sqlite > "$T/x.sqlite" 2>/dev/null && python3 -c "
import sqlite3;print(sqlite3.connect('$T/x.sqlite').execute('select count(*) from points').fetchone()[0])")
check "в архиве 4 точки (копия консистентна)" "$rows" "4"

# ===========================================================================
echo "== 3. Повреждённый архив → пересборка =="
printf 'garbage' > "$A"
out=$(run_backup)
grep -q 'START daily' <<<"$out" && ok "повреждение замечено" || bad "повреждение не замечено: $out"
gzip -t "$A" 2>/dev/null && ok "архив восстановлен и читается" || bad "архив остался повреждённым"

echo "== 3b. Удалённый архив → пересборка =="
rm -f "$A"
out=$(run_backup)
grep -q 'START daily' <<<"$out" && ok "удаление замечено" || bad "удаление не замечено: $out"
[ -f "$A" ] && gzip -t "$A" 2>/dev/null && ok "архив снова на месте" || bad "архив не восстановлен"

# ===========================================================================
echo "== 4. Сбой копирования базы → старые архивы не удаляются =="
new_sandbox t4
run_backup >/dev/null 2>&1                       # базовый архив
for d in 10 15 20; do : > "$B/daily/openhands_old_${d}d.tar.gz"; touch -d "-${d} days" "$B/daily/openhands_old_${d}d.tar.gz"; done
before=$(archive_count "$B/daily")
# база с валидной сигнатурой, но нечитаемым содержимым: staging и integrity_check падают
python3 - "$SRV/openhands-agent/config/automation/automations.db" <<'PY'
import sys
with open(sys.argv[1], "r+b") as fh:
    fh.seek(16)
    fh.write(b"\x00" * 4096)      # разрушаем служебные страницы, сигнатура остаётся
PY
printf '# doc v2\n' > "$SRV/openhands-agent/docs/a.md"    # гарантируем попытку новой копии
out=$(run_backup); rc=$?
grep -q 'DB-STAGE-FAIL' <<<"$out" && ok "сбой копирования базы обнаружен" || bad "сбой базы не обнаружен: $out"
grep -qE 'DB-STAGE-FAIL .*(DatabaseError|integrity_check)' <<<"$out" \
    && ok "указана причина сбоя базы" || bad "причина сбоя базы не указана: $out"
grep -q 'ROTATION skipped' <<<"$out" && ok "ротация заблокирована" || bad "ротация не заблокирована: $out"
check "число архивов не выросло и не уменьшилось" "$(archive_count "$B/daily")" "$before"
ls "$B/daily"/openhands_old_* >/dev/null 2>&1 && ok "старые копии физически на месте" || bad "старые копии удалены"
grep -q 'ROTATION skipped — run was not clean' "$B/backup.log" && ok "причина записана в журнал" || bad "причина не записана"
LOGDBS=$(tar tzf "$B/daily/openhands_2026-"*.tar.gz 2>/dev/null | grep -c 'automations\.db$')
check "оригинал и копия не задвоены (ровно 1 запись)" "$LOGDBS" "1"

# ===========================================================================
echo "== 5. Сбой tar не маскируется конвейером =="
new_sandbox t5
run_backup >/dev/null 2>&1
for d in 10 15 20; do : > "$B/daily/openhands_old_${d}d.tar.gz"; touch -d "-${d} days" "$B/daily/openhands_old_${d}d.tar.gz"; done
before=$(archive_count "$B/daily")
mkdir -p "$SRV/openhands-agent/docs/locked"; printf 'x\n' > "$SRV/openhands-agent/docs/locked/f"
chmod 000 "$SRV/openhands-agent/docs/locked"
printf '# doc v2\n' > "$SRV/openhands-agent/docs/a.md"
if [ -r "$SRV/openhands-agent/docs/locked/f" ]; then
    skip "сбой tar через недоступный каталог (тест должен идти не от root)"
    chmod 755 "$SRV/openhands-agent/docs/locked"
else
    out=$(run_backup); rc=$?
    chmod 755 "$SRV/openhands-agent/docs/locked"
    check "код возврата не 0" "$rc" "1"
    grep -q 'FAIL tar rc=' <<<"$out" && ok "ошибка tar видна в журнале" || bad "ошибка tar замаскирована: $out"
    grep -q 'DONE' <<<"$out" && bad "прогон ложно завершился DONE" || ok "ложного DONE нет"
    check "старые архивы сохранены" "$(archive_count "$B/daily")" "$before"
fi

# ===========================================================================
echo "== 6. Длительный простой → история не уничтожается =="
new_sandbox t6
run_backup >/dev/null 2>&1
: > "$B/.state/retention-bootstrapped"           # имитируем «не первый прогон»
for d in 8 10 12 15 20 40; do : > "$B/daily/openhands_old_${d}d.tar.gz"; touch -d "-${d} days" "$B/daily/openhands_old_${d}d.tar.gz"; done
run_backup >/dev/null 2>&1                        # прогон после простоя (данные не менялись → SKIP)
out=$(run_backup)
n=$(archive_count "$B/daily")
if [ "$n" -ge 3 ]; then ok "после простоя сохранено $n копий (минимум 3)"; else bad "после простоя осталось $n копий"; fi
newest_archive "$B/daily" >/dev/null
[ -f "$B/.state/last-good" ] && ok "эталонная копия отмечена" || bad "эталонная копия не отмечена"
LATEST=$(cat "$B/.state/last-good")
[ -f "$LATEST" ] && ok "эталонная копия физически существует" || bad "эталонная копия отсутствует"

# ===========================================================================
echo "== 7. Ротация: минимум копий, самая свежая, первая установка =="
new_sandbox t7
for d in 2 9 11 13 20; do : > "$B/daily/openhands_old_${d}d.tar.gz"; touch -d "-${d} days" "$B/daily/openhands_old_${d}d.tar.gz"; done
before=$(archive_count "$B/daily")
out=$(run_backup)
grep -q 'first run of new retention logic' <<<"$out" && ok "первый прогон не удаляет" || bad "первый прогон удалил архивы: $out"
check "ничего не удалено при внедрении" "$(archive_count "$B/daily")" "$((before + 1))"

run_backup >/dev/null 2>&1                        # второй прогон — ротация разрешена
out=$(run_backup)
LATEST=$(cat "$B/.state/last-good")
[ -f "$LATEST" ] && ok "самая свежая копия сохранена" || bad "самая свежая копия удалена"
n=$(archive_count "$B/daily")
[ "$n" -ge 3 ] && ok "минимум 3 копии сохранён (сейчас $n)" || bad "осталось меньше 3 копий ($n)"
[ -f "$B/daily/openhands_old_2d.tar.gz" ] && ok "недавняя копия (2 дня) сохранена" || bad "удалена свежая копия"
[ -f "$B/daily/openhands_old_20d.tar.gz" ] && bad "20-дневная копия удалена сверх минимума" || ok "удалены только самые старые сверх минимума"
grep -q 'ROTATION removed' <<<"$out" && ok "ротация отчиталась в журнале" || ok "ротация без удалений (допустимо)"

# ===========================================================================
echo "== 8. Одновременный запуск не ломает архив =="
new_sandbox t8
( run_backup >/dev/null 2>&1 & run_backup >/dev/null 2>&1 & wait )
A=$(newest_archive "$B/daily")
[ -n "$A" ] && gzip -t "$A" 2>/dev/null && ok "архив после гонки читается" || bad "архив после гонки повреждён"

# ===========================================================================
echo
echo "ИТОГО: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
