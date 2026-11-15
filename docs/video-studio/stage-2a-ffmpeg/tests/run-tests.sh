#!/usr/bin/env bash
# Стенд проверки host- и scripts-скриптов без реальных блочных устройств.
#
# Ничего не форматирует, не разметает, не монтирует и не пишет в /etc/fstab.
# Каждый сценарий исполняется в своём каталоге mktemp: скрипты копируются,
# у копий подменяются только пути и проверка «является ли файл блочным
# устройством», а внешние команды (lsblk, findmnt, sgdisk, mkfs.ext4, mount,
# df, blkid, swapon, systemctl, chown, id) заменяются подставными из $PATH.
#
# Что именно подменяется в копиях — перечислено в patch_ssd() и patch_loop().
# Логика, порядок шагов, откат и защита от повторного запуска проверяются
# настоящим текстом скрипта.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMPROOT=$(mktemp -d /tmp/vs-tests.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  ПРОЙДЕНО: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  НЕ ПРОЙДЕНО: %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n== %s ==\n' "$1"; }

# --- подставные команды ------------------------------------------------------

make_fakes() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/lsblk" <<'EOF'
#!/bin/sh
st="$FAKE_STATE"
serial="${FAKE_SERIAL:-24257G400264}"
[ -f "$st/serial_changed" ] && serial="9999CHANGED"
case "${1:-} ${2:-}" in
  "-dno SERIAL")        echo "$serial" ;;
  "-dno MODEL")         echo "Extreme 55AE" ;;
  "-dno TRAN")          echo "usb" ;;
  "-dno PTTYPE")        [ -f "$st/zapped" ] && echo gpt || echo "${FAKE_PTTYPE:-dos}" ;;
  "-no PARTTYPE")       [ -n "${FAKE_PARTTYPE:-}" ] && echo "$FAKE_PARTTYPE"; true ;;
  "-no PARTLABEL")      [ -n "${FAKE_PARTLABEL:-}" ] && echo "$FAKE_PARTLABEL"; true ;;
  "-no NAME")           echo "$FAKE_DEV"; [ -e "${FAKE_DEV}-part1" ] && echo "${FAKE_DEV}-part1"; true ;;
  "-bno START")         [ -e "${FAKE_DEV}-part1" ] && echo "${FAKE_PART_START:-2048}"; true ;;
  "-bno SIZE")          [ -e "${FAKE_DEV}-part1" ] && echo "${FAKE_PART_BYTES:-1000203837440}"; true ;;
  "-bdno SIZE")         echo "${FAKE_SIZE:-1000204886016}" ;;
  "-no LABEL")          [ -n "${FAKE_LABEL:-}" ] && echo "$FAKE_LABEL"; true ;;
  "-no FSTYPE")         f=$(cat "$st/sig" 2>/dev/null); [ -n "$f" ] && echo "$f" || { [ -n "${FAKE_FSTYPE:-}" ] && echo "$FAKE_FSTYPE"; true; } ;;
  "-no PKNAME")         echo sdz ;;
  "-pno NAME,MOUNTPOINTS") [ "${FAKE_MOUNTED:-0}" = 1 ] && echo "${FAKE_DEV}-part1 $FAKE_MOUNT" || echo "${FAKE_DEV}-part1 "; true ;;
  "-o NAME,SIZE,FSTYPE") echo "${FAKE_DEV} 931.5G ext4 VIDEO_STUDIO $FAKE_MOUNT" ;;
  *) true ;;
esac
EOF

  cat > "$bin/findmnt" <<'EOF'
#!/bin/sh
st="$FAKE_STATE"
mounted() { [ "${FAKE_MOUNTED:-0}" = 1 ] || [ -f "$st/mounted" ]; }
case "${1:-}" in
  --verify)
    # FAKE_VERIFY_FAIL=1 — проверка fstab не проходит; FAKE_VERIFY_OUT задаёт
    # строки диагностики, чтобы различать «наша строка» и «чужая».
    if [ "${FAKE_VERIFY_FAIL:-0}" = 1 ]; then
      echo "${FAKE_VERIFY_OUT:-0 parse errors, 1 errors, 0 warnings}"
      exit 1
    fi
    exit 0 ;;
  -S) mounted && { echo "$FAKE_MOUNT"; exit 0; }; exit 1 ;;
  -no)
    case "${2:-}" in
      TARGET)   mounted && { echo "$FAKE_MOUNT"; exit 0; }; exit 1 ;;
      SOURCE)   echo "${FAKE_SOURCE:-${FAKE_DEV}-part1}" ;;
      FSTYPE)   echo ext4 ;;
      SOURCE,FSTYPE,SIZE,OPTIONS) echo "${FAKE_DEV}-part1 ext4 40G rw,nofail" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF

  cat > "$bin/df" <<'EOF'
#!/bin/sh
case "$*" in
  *-BG*--output=size*) printf 'Size\n%sG\n' "$(( ${FAKE_TOTAL_KI:-41943040} / 1048576 ))" ;;
  *--output=size*)     printf 'Size\n%s\n' "${FAKE_TOTAL_KI:-41943040}" ;;
  *--output=avail*)    printf 'Avail\n%sG\n' "${FAKE_HOST_FREE_GIB:-500}" ;;
  *--output=used*)     printf 'Used\n%sG\n' "${FAKE_USED_GIB:-0}" ;;
  *-Pm*) printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
         printf '%s %s %s %s 1%% %s\n' "${FAKE_DEV}-part1" "$(( ${FAKE_TOTAL_KI:-41943040} / 1024 ))" "${FAKE_USED_MIB:-10}" "${FAKE_FREE_MIB:-40000}" "$FAKE_MOUNT" ;;
  *-Pk*) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
         printf '%s %s %s %s 1%% %s\n' "${FAKE_DEV}-part1" "${FAKE_TOTAL_KI:-41943040}" 10240 40960000 "$FAKE_MOUNT" ;;
  *-h*)  printf 'Filesystem Size Used Avail Use%% Mounted on\n'
         printf '%s 40G 10M 40G 1%% %s\n' "${FAKE_DEV}-part1" "$FAKE_MOUNT" ;;
  *) exit 1 ;;
esac
EOF

  cat > "$bin/sgdisk" <<'EOF'
#!/bin/sh
echo "sgdisk $*" >> "$FAKE_LOG"
case "$*" in
  *--zap-all*)
    touch "$FAKE_STATE/zapped"
    [ "${FAKE_SERIAL_SWITCH:-0}" = 1 ] && touch "$FAKE_STATE/serial_changed"
    ;;
  *--new*)
    : > "$(dirname "$FAKE_DEV")/real1"
    ln -sfn real1 "${FAKE_DEV}-part1"
    ;;
esac
exit 0
EOF

  cat > "$bin/mkfs.ext4" <<'EOF'
#!/bin/sh
echo "mkfs.ext4 $*" >> "$FAKE_LOG"
# Приглашение mke2fs при неинтерактивном запуске обязано быть невозможно:
# stdin должен быть /dev/null, иначе сценарий D4 повторяется.
stdin_link=$(readlink /proc/self/fd/0 2>/dev/null)
if [ "$stdin_link" != "/dev/null" ]; then
  echo "stdin-bad: mkfs.ext4 получил $stdin_link" >> "$FAKE_LOG"
  : > "$FAKE_STATE/mkfs_stdin_bad"
fi
[ "${FAKE_MKFS_FAIL:-0}" = 1 ] && { echo "mkfs.ext4: отказ (подставной)" >&2; exit 1; }
echo ext4 > "$FAKE_STATE/sig"
echo "${FAKE_UUID:-test-uuid-1234}" > "$FAKE_STATE/uuid"
exit 0
EOF

  # Коды возврата как у настоящего blkid 2.41: 0 — токен найден (или объект
  # опознан, но токена TYPE у него нет), 2 — ничего не опознано; при ошибке
  # чтения тоже 2, но с текстом в stderr. На отсутствующий путь — 2 без текста.
  cat > "$bin/blkid" <<'EOF'
#!/bin/sh
echo "blkid $*" >> "$FAKE_LOG"
st="$FAKE_STATE"
dev=""; token=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--match-tag) token="$2"; shift ;;
    -o|--output) shift ;;
    -p|--probe|-t|--poll) ;;
    -*) ;;
    *) dev="$1" ;;
  esac
  shift
done
[ "${FAKE_BLKID_FAIL_NOSTDERR:-0}" = 1 ] && exit 4
[ -n "$dev" ] && [ ! -e "$dev" ] && exit 2
[ "${FAKE_BLKID_DENIED:-0}" = 1 ] && { echo "blkid: error: $dev: Permission denied" >&2; exit 2; }
sig=$(cat "$st/sig" 2>/dev/null)
uuid=$(cat "$st/uuid" 2>/dev/null)
[ -n "$uuid" ] || uuid="${FAKE_UUID:-test-uuid-1234}"
case "$token" in
  TYPE)
    [ -n "$sig" ] && { echo "$sig"; exit 0; }
    # Таблица разделов без файловой системы: код 0, но токена TYPE нет.
    [ "${FAKE_BLKID_DOS_ONLY:-0}" = 1 ] && exit 0
    exit 2 ;;
  UUID) [ -n "$sig" ] || exit 2; echo "$uuid" ;;
  *) echo "$uuid" ;;
esac
EOF

  cat > "$bin/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$FAKE_LOG"
[ "${FAKE_MOUNT_FAIL:-0}" = 1 ] && { echo "mount: не удалось" >&2; exit 32; }
touch "$FAKE_STATE/mounted"
exit 0
EOF

  cat > "$bin/umount" <<'EOF'
#!/bin/sh
echo "umount $*" >> "$FAKE_LOG"
rm -f "$FAKE_STATE/mounted"
exit 0
EOF

  cat > "$bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$FAKE_LOG"
exit 0
EOF
  cat > "$bin/partprobe" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$bin/udevadm" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$bin/swapon" <<'EOF'
#!/bin/sh
exit 0
EOF

  # Формат и коды возврата как у util-linux 2.41: по умолчанию печатается
  # DEVICE OFFSET TYPE UUID LABEL, поэтому разбор по положению столбца на этом
  # выводе даёт пустоту. Ошибка открытия — код 1 и текст в stderr.
  cat > "$bin/wipefs" <<'EOF'
#!/bin/sh
echo "wipefs $*" >> "$FAKE_LOG"
st="$FAKE_STATE"
dev=""; output=""; noact=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--no-act) noact=1 ;;
    -i|--noheadings|-a|--all|-q|--quiet|-f|--force) ;;
    -O|--output) output="$2"; shift ;;
    --output=*) output="${1#*=}" ;;
    -*) ;;
    *) dev="$1" ;;
  esac
  shift
done
[ -n "$dev" ] || { echo "wipefs: error: no device specified" >&2; exit 1; }
[ -e "$dev" ] || { echo "wipefs: error: $dev: probing initialization failed: No such file or directory" >&2; exit 1; }
[ -r "$dev" ] || { echo "wipefs: error: $dev: probing initialization failed: Permission denied" >&2; exit 1; }
sig=$(cat "$st/sig" 2>/dev/null)
if [ "$noact" = 1 ]; then
  [ "${FAKE_WIPEFS_PROBE_FAIL:-0}" = 1 ] && {
    echo "wipefs: error: $dev: probing initialization failed: Input/output error" >&2; exit 1; }
  if [ -n "$output" ]; then
    case "$output" in
      TYPE) [ -n "$sig" ] && echo "$sig" ;;
      OFFSET|OFFSET,TYPE) [ -n "$sig" ] && printf '0x3 %s\n' "$sig" ;;
      *) echo "wipefs: error: unsupported column: $output" >&2; exit 1 ;;
    esac
  else
    printf 'DEVICE    OFFSET TYPE UUID LABEL\n'
    [ -n "$sig" ] && printf '%s 0x3    %s\n' "$dev" "$sig"
  fi
  exit 0
fi
[ "${FAKE_WIPEFS_FAIL:-0}" = 1 ] && { echo "wipefs: error: $dev: erase failed" >&2; exit 1; }
[ "${FAKE_WIPEFS_KEEP:-0}" = 1 ] || : > "$st/sig"
exit 0
EOF

  cat > "$bin/fuser" <<'EOF'
#!/bin/sh
[ "${FAKE_FUSER_BUSY:-0}" = 1 ] || exit 1
[ "${1:-}" = "-s" ] && exit 0
echo "  4242"
exit 0
EOF
  cat > "$bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$FAKE_LOG"
exit 0
EOF
  cat > "$bin/id" <<'EOF'
#!/bin/sh
[ "${FAKE_ROOT:-0}" = 1 ] && echo 0 || echo 1000
EOF
  cat > "$bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$FAKE_LOG"
exit 1
EOF
  chmod +x "$bin"/*
}

# --- подготовка песочницы ----------------------------------------------------

# В копиях меняется только то, что нельзя подделать снаружи: путь устройства,
# точка монтирования, путь fstab и встроенная проверка «это блочное
# устройство» (подставной файл блочным не станет).
patch_ssd() {
  local f="$1"
  sed -i \
    -e "s|^readonly DEV=.*|readonly DEV=\"$FAKE_DEV\"|" \
    -e "s|^readonly MOUNT=.*|readonly MOUNT=\"$FAKE_MOUNT\"|" \
    -e "s|^readonly FSTAB=.*|readonly FSTAB=\"$FAKE_FSTAB\"|" \
    -e 's|\[ -b "\$real" \] \|\| die|[ -e "$real" ] \|\| die|' \
    -e 's|\[ -b "\${DEV}-part1" \] \|\| die|[ -e "${DEV}-part1" ] \|\| die|' \
    "$f"
}

patch_loop() {
  local f="$1"
  # Проверка «-b IMAGE» в песочнице всегда ложна (подставной файл не блочный),
  # поэтому она отключается целиком. Проверка «файл уже существует» остаётся
  # настоящей — именно она проверяется в L3.
  sed -i \
    -e "s|^readonly IMAGE=.*|readonly IMAGE=\"$FAKE_IMAGE\"|" \
    -e "s|^readonly MOUNT=.*|readonly MOUNT=\"$FAKE_MOUNT\"|" \
    -e "s|^readonly FSTAB=.*|readonly FSTAB=\"$FAKE_FSTAB\"|" \
    -e 's|\[ -b "\$IMAGE" \] && die|:|' \
    "$f"
}

setup_env() {
  SB=$(mktemp -d "$TMPROOT/case.XXXXXX")
  export FAKE_STATE="$SB/state"
  export FAKE_MOUNT="$SB/mnt"
  export FAKE_DEV="$SB/dev/ssd"
  export FAKE_IMAGE="$SB/video-data.img"
  export FAKE_FSTAB="$SB/fstab"
  export FAKE_LOG="$SB/cmd.log"
  export FAKE_SOURCE="${FAKE_DEV}-part1"
  mkdir -p "$FAKE_STATE" "$SB/dev" "$SB/host" "$SB/scripts" "$SB/bin" "$FAKE_MOUNT"
  : > "$FAKE_LOG"
  printf '%s\n' \
    '/dev/mapper/ubuntu--vg-ubuntu--lv / ext4 defaults 0 1' \
    'uuid-ceil /boot ext4 defaults 0 1' \
    'UUID=amnesia /mnt/amnesia-backup ext4 defaults,nofail 0 2' > "$FAKE_FSTAB"
  cp "$FAKE_FSTAB" "$SB/fstab.orig"
  # by-id в жизни всегда ссылка, поэтому и в песочнице ссылка.
  : > "$SB/dev/real"
  ln -s real "$FAKE_DEV"
  make_fakes "$SB/bin"
  cp "$SRC/size-check.sh" "$SB/"
  export PATH="$SB/bin:$PATH"
  unset FAKE_MOUNTED FAKE_MOUNT_FAIL FAKE_VERIFY_FAIL FAKE_LABEL FAKE_PTTYPE \
        FAKE_SERIAL_SWITCH FAKE_SERIAL FAKE_ROOT FAKE_HOST_FREE_GIB \
        FAKE_TOTAL_KI MIN_GIB FAKE_PARTTYPE FAKE_PARTLABEL FAKE_PART_START \
        FAKE_PART_BYTES FAKE_FUSER_BUSY FAKE_WIPEFS_FAIL FAKE_WIPEFS_KEEP \
        FAKE_MKFS_FAIL FAKE_UUID FAKE_WIPEFS_PROBE_FAIL FAKE_BLKID_DOS_ONLY \
        FAKE_BLKID_FAIL_NOSTDERR FAKE_BLKID_DENIED
}

# Для проверок verify-storage: смонтированное хранилище с маркером и записью
# в fstab, иначе скрипт останавливается раньше ворот --fill.
seed_verify_env() {
  local marker="$1" total_ki="$2" prod_mount="$3"
  cp "$SRC/scripts/verify-storage.sh" "$SB/scripts/"
  cp "$SRC/size-check.sh" "$SB/"
  sed -i -e "s|^PRODUCTION_MOUNT=.*|PRODUCTION_MOUNT=\"$prod_mount\"|" \
         -e "s|^ROOT=.*|ROOT=\"$SB\"|" \
         -e "s|/etc/fstab|$FAKE_FSTAB|g" "$SB/scripts/verify-storage.sh"
  echo "$marker" > "$FAKE_MOUNT/.storage-size-gib"
  printf 'UUID=x %s ext4 defaults,nofail 0 2\n' "$FAKE_MOUNT" >> "$FAKE_FSTAB"
  export FAKE_MOUNTED=1 FAKE_TOTAL_KI="$total_ki" FAKE_SOURCE=/dev/loop7
  export MOUNT="$FAKE_MOUNT"
}

patch_remove() {
  local f="$1"
  sed -i \
    -e "s|^readonly MOUNT=.*|readonly MOUNT=\"$FAKE_MOUNT\"|" \
    -e "s|^readonly IMAGE=.*|readonly IMAGE=\"$FAKE_IMAGE\"|" \
    -e "s|^readonly PROJECT_DIR=.*|readonly PROJECT_DIR=\"$SB\"|" \
    -e "s|^readonly FSTAB=.*|readonly FSTAB=\"$FAKE_FSTAB\"|" \
    "$f"
  # В песочнице нет настоящих /dev-узлов: признак блочности подменяется
  # проверкой непустого имени, а loop-источник узнаётся по суффиксу -part1.
  python3 - "$f" <<'PYREMOVE'
import sys
p = sys.argv[1]
s = open(p).read()
pairs = [
    ('    /dev/loop*) : ;;', '    /dev/loop*|*-part1) : ;;'),
    ('    /dev/*) [ -b "$source" ] && is_partition=1 ;;', '    /dev/*) [ -n "$source" ] && is_partition=1 ;;'),
    ('if [ "$DELETE_IMAGE" = "1" ] && [ -b "$IMAGE" ]; then', 'if false; then'),
]
for old, repl in pairs:
    assert old in s, old
    s = s.replace(old, repl, 1)
open(p, "w").write(s)
PYREMOVE
}

patch_resize() {
  local f="$1"
  sed -i \
    -e "s|^readonly MOUNT=.*|readonly MOUNT=\"$FAKE_MOUNT\"|" \
    -e "s|^readonly IMAGE=.*|readonly IMAGE=\"$FAKE_IMAGE\"|" \
    "$f"
  python3 - "$f" <<'PYRESIZE'
import sys
p = sys.argv[1]
s = open(p).read()
pairs = [
    ('  /dev/loop*) : ;;', '  /dev/loop*|*-part1) : ;;'),
    ('    if [ -b "$source_loop" ]; then', '    if [ -n "$source_loop" ]; then'),
    ('[ -b "$IMAGE" ] && die', 'false && die'),
]
for old, repl in pairs:
    assert old in s, old
    s = s.replace(old, repl, 1)
open(p, "w").write(s)
PYRESIZE
}

run_ssd() {
  bash "$SB/host/setup-ssd-storage.sh" "$@"
}
run_loop() {
  bash "$SB/host/setup-storage.sh" "$@"
}
# Узел раздела в /dev — отдельная ссылка на тот же диск. В песочнице это
# symlink, иначе проверка «раздел принадлежит этому диску» ничего не значит.
make_part() {
  : > "$SB/dev/real1"
  ln -sfn real1 "${FAKE_DEV}-part1"
}
# Состояние «первая попытка уже создала разметку и раздел».
make_expected_layout() {
  make_part
  export FAKE_PTTYPE=gpt FAKE_PARTTYPE=0fc63daf-8483-4772-8e79-3d69d8477de4
  export FAKE_PARTLABEL=VIDEO_STUDIO
}
plan_lines() { grep -c '^  ' "$1" 2>/dev/null || true; }
exec_lines() { grep -c '^+ ' "$1" 2>/dev/null || true; }

# =============================================================================
head_ "S1. setup-ssd-storage.sh: примерка ничего не исполняет"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$("$SB/host/setup-ssd-storage.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || bad "код $rc"
printf '%s' "$out" > "$SB/out.txt"
[ "$(exec_lines "$SB/out.txt")" = 0 ] && ok "ни одной исполненной команды ('+ ')" \
  || bad "в примере есть исполнение: $(grep '^+ ' "$SB/out.txt" | head -3)"
[ ! -s "$FAKE_LOG" ] && ok "журнал внешних команд пуст" \
  || bad "в примере вызваны команды: $(head -3 "$FAKE_LOG")"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" || bad "fstab изменён в примере"
[ ! -e "${FAKE_DEV}-part1" ] && ok "раздел не создан" || bad "раздел создан в примере"
[ ! -f "$FAKE_STATE/mounted" ] && ok "ничего не смонтировано" || bad "появилось монтирование"
n=$(grep -c '^  ' "$SB/out.txt")
[ "$n" -ge 8 ] && ok "в плане $n шагов" || bad "в плане всего $n шагов"
for s in "sgdisk --zap-all" "sgdisk --new=1:0:0" "wipefs -a" "mkfs.ext4" "stdin от /dev/null" "fstab" "создать точку монтирования" "mount" "маркер"; do
  grep -qF "$s" "$SB/out.txt" && ok "план содержит: $s" || bad "в плане нет: $s"
done
grep -q "Ничего не изменено" "$SB/out.txt" && ok "сказано, что изменений нет" || bad "нет предупреждения"

# =============================================================================
head_ "S2. setup-ssd-storage.sh: --apply без root"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=0 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "скрипт не отказал"
printf '%s' "$out" | grep -q "нужен root" && ok "причина названа" || bad "нет сообщения о root"
[ ! -s "$FAKE_LOG" ] && ok "ни одна внешняя команда не вызвана" || bad "вызваны: $(head -3 "$FAKE_LOG")"
[ ! -e "${FAKE_DEV}-part1" ] && ok "раздел не создан" || bad "раздел создан"

# =============================================================================
head_ "S3. setup-ssd-storage.sh: неверное подтверждение серийного номера"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial WRONG 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "скрипт не отказал"
printf '%s' "$out" | grep -q "подтверждение не совпало" && ok "причина названа" || bad "нет сообщения"
[ ! -s "$FAKE_LOG" ] && ok "ни одна внешняя команда не вызвана" || bad "вызваны: $(head -3 "$FAKE_LOG")"

# =============================================================================
head_ "S4. setup-ssd-storage.sh: полный --apply на подставном устройстве"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -5 "$SB/out.txt"; }
[ "$(grep -c '^sgdisk --zap-all' "$FAKE_LOG")" = 1 ] && ok "sgdisk --zap-all ровно один раз" \
  || bad "sgdisk --zap-all: $(grep -c '^sgdisk --zap-all' "$FAKE_LOG") раз"
[ "$(grep -c '^sgdisk --new' "$FAKE_LOG")" = 1 ] && ok "создание раздела один раз" \
  || bad "создание раздела: $(grep -c '^sgdisk --new' "$FAKE_LOG") раз"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 1 ] && ok "mkfs.ext4 ровно один раз" \
  || bad "mkfs.ext4: $(grep -c '^mkfs.ext4' "$FAKE_LOG") раз"
[ "$(grep -c '^mount ' "$FAKE_LOG")" = 1 ] && ok "mount один раз" || bad "mount: $(grep -c '^mount ' "$FAKE_LOG") раз"
ln_fstab=$(grep -n "ИЗМЕНЕНО" "$SB/out.txt" | cut -d: -f1)
ln_mount=$(grep -n '^+ mount' "$SB/out.txt" | cut -d: -f1)
[ -n "$ln_fstab" ] && [ -n "$ln_mount" ] && [ "$ln_fstab" -lt "$ln_mount" ] \
  && ok "fstab записан до mount (строки $ln_fstab < $ln_mount)" \
  || bad "порядок нарушен: fstab=$ln_fstab mount=$ln_mount"
[ "$(wc -l < "$FAKE_FSTAB")" = 4 ] && ok "в fstab ровно 4 записи (было 3)" \
  || bad "в fstab $(wc -l < "$FAKE_FSTAB") записей"
head -3 "$FAKE_FSTAB" | cmp -s - "$SB/fstab.orig" && ok "старые строки fstab не тронуты" \
  || bad "старые строки fstab изменились"
grep -q "UUID=test-uuid-1234 $FAKE_MOUNT ext4" "$FAKE_FSTAB" && ok "новая строка по UUID" \
  || bad "новая строка неверна"
[ -f "$FAKE_MOUNT/.storage-size-gib" ] && ok "маркер записан" || bad "маркера нет"
[ "$(cat "$FAKE_MOUNT/.storage-size-gib")" = 40 ] && ok "маркер 40 GiB" \
  || bad "маркер $(cat "$FAKE_MOUNT/.storage-size-gib" 2>/dev/null)"
for d in in out tmp archive; do
  [ -d "$FAKE_MOUNT/$d" ] && ok "каталог $d создан" || bad "каталога $d нет"
done

# =============================================================================
head_ "S4b. setup-ssd-storage.sh: точки монтирования нет — создаётся до mount"
setup_env
rmdir "$FAKE_MOUNT"
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
# mount не создаёт каталог. Если шаг создания отсутствует, mount падает уже
# после mkfs и откат оставляет отформатированный раздел.
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; printf '%s\n' "$out" | tail -4; }
[ -d "$FAKE_MOUNT" ] && ok "точка монтирования создана" || bad "каталога $FAKE_MOUNT нет"
[ "$(grep -c '^mount ' "$FAKE_LOG")" = 1 ] && ok "mount выполнен один раз" \
  || bad "mount: $(grep -c '^mount ' "$FAKE_LOG") раз"
ln_mkdir=$(grep -n '^+ создать точку монтирования' <<<"$out" | cut -d: -f1)
ln_fstab=$(grep -n '^+ добавить строку UUID' <<<"$out" | cut -d: -f1)
ln_mount=$(grep -n '^+ mount' <<<"$out" | cut -d: -f1)
[ -n "$ln_mkdir" ] && [ -n "$ln_fstab" ] && [ "$ln_mkdir" -lt "$ln_fstab" ] \
  && ok "каталог создан до записи fstab (строки $ln_mkdir < $ln_fstab)" \
  || bad "порядок нарушен: каталог=$ln_mkdir fstab=$ln_fstab"
[ -n "$ln_fstab" ] && [ -n "$ln_mount" ] && [ "$ln_fstab" -lt "$ln_mount" ] \
  && ok "fstab записан до mount (строки $ln_fstab < $ln_mount)" \
  || bad "порядок нарушен: fstab=$ln_fstab mount=$ln_mount"
[ -f "$FAKE_MOUNT/.storage-size-gib" ] && ok "маркер записан" || bad "маркера нет"

# =============================================================================
head_ "S4c. setup-ssd-storage.sh: модуль сверки размера только в image/ffmpeg"
setup_env
rm -f "$SB/size-check.sh"
mkdir -p "$SB/image/ffmpeg"
cp "$SRC/size-check.sh" "$SB/image/ffmpeg/size-check.sh"
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0 на серверной раскладке" \
  || { bad "код $rc"; printf '%s\n' "$out" | tail -4; }
[ -f "$FAKE_MOUNT/.storage-size-gib" ] && ok "маркер записан" || bad "маркера нет"

# =============================================================================
head_ "S4d. setup-ssd-storage.sh: модуля нет нигде — отказ до первой команды"
setup_env
rm -f "$SB/size-check.sh"
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "скрипт не отказал"
printf '%s' "$out" | grep -q "не найден size-check.sh" && ok "причина названа" || bad "нет сообщения"
[ ! -s "$FAKE_LOG" ] && ok "ни одна внешняя команда не вызвана" || bad "вызваны: $(head -2 "$FAKE_LOG")"
[ ! -e "${FAKE_DEV}-part1" ] && ok "раздел не создан" || bad "раздел создан"

# =============================================================================
head_ "S4e. setup-ssd-storage.sh: verify не видит источник — только своей строки"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
export FAKE_VERIFY_FAIL=1
export FAKE_VERIFY_OUT="0 parse errors, 1 errors, 0 warnings
$FAKE_MOUNT
   [E] unreachable on boot required source: UUID=test-uuid-1234"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0: ожидаемая ошибка не блокирует" \
  || { bad "код $rc"; printf '%s\n' "$out" | tail -4; }
printf '%s' "$out" | grep -q "ещё не виден в by-uuid" && ok "причина названа" || bad "нет пояснения"
[ "$(grep -c '^mount ' "$FAKE_LOG")" = 1 ] && ok "mount выполнен" || bad "mount не выполнен"
grep -q "UUID=test-uuid-1234 $FAKE_MOUNT" "$FAKE_FSTAB" && ok "строка в fstab записана" || bad "строки нет"

# =============================================================================
head_ "S4f. setup-ssd-storage.sh: verify нашёл чужую ошибку — отказ, fstab цел"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
export FAKE_VERIFY_FAIL=1
export FAKE_VERIFY_OUT="0 parse errors, 1 errors, 0 warnings
/boot
   [E] unreachable on boot required source: UUID=someone-else"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "скрипт не отказал"
printf '%s' "$out" | grep -q "не прошла проверку" && ok "причина названа" || bad "нет сообщения"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" || bad "fstab изменён"
[ "$(grep -c '^mount ' "$FAKE_LOG")" = 0 ] && ok "mount не выполнялся" || bad "mount выполнен"

# =============================================================================
head_ "S4g. setup-ssd-storage.sh: ошибка разбора fstab — отказ"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
export FAKE_VERIFY_FAIL=1
export FAKE_VERIFY_OUT="1 parse errors, 0 errors, 0 warnings
$FAKE_MOUNT
   [E] unknown option"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "скрипт не отказал"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" || bad "fstab изменён"

# =============================================================================
head_ "S5. setup-ssd-storage.sh: повторный запуск после успеха"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
first=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" = 0 ] && ok "первый --apply прошёл" || { bad "первый --apply: код $rc"; printf '%s\n' "$first" | tail -4; }
cp "$FAKE_LOG" "$SB/log.before"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; printf '%s\n' "$out" | tail -3; }
printf '%s' "$out" | grep -q "УЖЕ НАСТРОЕНО" && ok "сообщает, что уже настроено" || bad "нет сообщения"
cmp -s "$FAKE_LOG" "$SB/log.before" && ok "ни одной новой внешней команды" \
  || bad "выполнено: $(diff "$SB/log.before" "$FAKE_LOG" | head -3)"
[ "$(wc -l < "$FAKE_FSTAB")" = 4 ] && ok "дубля строки в fstab нет" || bad "fstab раздулся"

# =============================================================================
head_ "S6. setup-ssd-storage.sh: подмена через окружение не работает"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(DEV=/dev/sda EXPECT_SERIAL=WRONG FORBIDDEN_SERIALS="" MOUNT=/tmp/evil \
      LABEL=EVIL FSTAB=/tmp/evil-fstab FAKE_ROOT=1 \
      "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0: подмена проигнорирована" || bad "код $rc"
printf '%s' "$out" | grep -qF "$FAKE_DEV" && ok "использован зашитый путь устройства" \
  || bad "путь устройства подменён"
printf '%s' "$out" | grep -q "/dev/sda" && bad "принят DEV=/dev/sda" || ok "DEV из среды не принят"
[ ! -e /tmp/evil-fstab ] && ok "FSTAB из среды не принят" || { bad "записано в /tmp/evil-fstab"; rm -f /tmp/evil-fstab; }
[ ! -d /tmp/evil ] && ok "MOUNT из среды не принят" || { bad "создан /tmp/evil"; rm -rf /tmp/evil; }
grep -q "VIDEO_STUDIO" "$FAKE_LOG" && ok "метка VIDEO_STUDIO зашита" || bad "метка подменена"

# =============================================================================
head_ "S7. setup-ssd-storage.sh: --reformat не принимается"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --reformat 2>&1); rc=$?
[ "$rc" = 2 ] && ok "код 2 (неизвестный аргумент)" || bad "код $rc"
printf '%s' "$out" | grep -q "неизвестный аргумент" && ok "причина названа" || bad "нет сообщения"
[ ! -s "$FAKE_LOG" ] && ok "ничего не выполнено" || bad "вызваны команды"

# =============================================================================
head_ "S8. setup-ssd-storage.sh: метка VIDEO_STUDIO уже есть"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 FAKE_LABEL=VIDEO_STUDIO "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "переформатирование разрешено"
printf '%s' "$out" | grep -q "не совпадает с ожидаемой" && ok "разметка не совпала — отказ" || bad "нет сообщения о расхождении"
printf '%s' "$out" | grep -q "разберитесь в состоянии диска вручную" && ok "дан ручной путь" || bad "нет инструкции"
[ ! -s "$FAKE_LOG" ] && ok "устройство не тронуто" || bad "вызваны: $(head -2 "$FAKE_LOG")"

# =============================================================================
head_ "S9. setup-ssd-storage.sh: точка монтирования занята файлами"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
echo "важный файл" > "$FAKE_MOUNT/data.txt"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск разрешён"
printf '%s' "$out" | grep -q "не пуст" && ok "причина названа" || bad "нет сообщения"
[ -f "$FAKE_MOUNT/data.txt" ] && ok "файл не удалён" || bad "файл удалён"

# =============================================================================
head_ "S10. setup-ssd-storage.sh: отказ mount — откат fstab, ФС не стирается"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 FAKE_MOUNT_FAIL=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "ошибка не замечена"
printf '%s' "$out" | grep -q "Откат после ошибки" && ok "откат выполнен" || bad "отката нет"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab восстановлен побайтно" \
  || bad "fstab не восстановлен: $(cat "$FAKE_FSTAB")"
[ -e "${FAKE_DEV}-part1" ] && ok "раздел оставлен (не стирается автоматически)" || bad "раздел исчез"
printf "%s" "$out" | grep -q "не удаляются автоматически" && ok "состояние объяснено" || bad "нет объяснения"

# =============================================================================
head_ "S11. setup-ssd-storage.sh: fstab не прошёл findmnt --verify"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 FAKE_VERIFY_FAIL=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "ошибка не замечена"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" \
  || bad "fstab изменён при непройденной проверке"
[ ! -f "$FAKE_STATE/mounted" ] && ok "монтирования не было" || bad "смонтировано"
printf "%s" "$out" | grep -q "не прошла проверку" && ok "причина названа" || bad "нет сообщения"

# =============================================================================
head_ "S12. setup-ssd-storage.sh: устройство подменили между проверкой и mkfs"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
out=$(FAKE_ROOT=1 FAKE_SERIAL_SWITCH=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "форматирование разрешено"
printf '%s' "$out" | grep -q "серийный номер изменился" && ok "причина названа" || bad "нет сообщения"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнен" || bad "mkfs выполнен на подменённом устройстве"

# =============================================================================
head_ "S13. setup-ssd-storage.sh: устройства нет"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
rm -f "$FAKE_DEV"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск разрешён"
printf '%s' "$out" | grep -q "не найден" && ok "причина названа" || bad "нет сообщения"

# =============================================================================
head_ "S14. setup-ssd-storage.sh: старая сигнатура NTFS — wipefs до mkfs"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -6 "$SB/out.txt"; }
[ "$(grep -c '^sgdisk' "$FAKE_LOG")" = 0 ] && ok "разметка не пересоздавалась" \
  || bad "sgdisk вызван: $(grep '^sgdisk' "$FAKE_LOG" | head -2)"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 1 ] && ok "wipefs -a ровно один раз" \
  || bad "wipefs -a: $(grep -c '^wipefs -a' "$FAKE_LOG") раз"
grep '^wipefs -a' "$FAKE_LOG" | grep -qF "${FAKE_DEV}-part1" \
  && ok "wipefs только по разделу" || bad "wipefs адресован не разделу: $(grep '^wipefs -a' "$FAKE_LOG")"
grep '^wipefs -a' "$FAKE_LOG" | grep -qxF "wipefs -a $FAKE_DEV" \
  && bad "wipefs по всему диску" || ok "wipefs по диску не вызывался"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 1 ] && ok "mkfs.ext4 ровно один раз" \
  || bad "mkfs.ext4: $(grep -c '^mkfs.ext4' "$FAKE_LOG") раз"
lw=$(grep -n '^wipefs -a' "$FAKE_LOG" | cut -d: -f1)
lm=$(grep -n '^mkfs.ext4' "$FAKE_LOG" | cut -d: -f1)
[ -n "$lw" ] && [ -n "$lm" ] && [ "$lw" -lt "$lm" ] \
  && ok "wipefs выполнен до mkfs ($lw < $lm)" || bad "порядок: wipefs=$lw mkfs=$lm"
[ ! -f "$FAKE_STATE/mkfs_stdin_bad" ] && ok "mkfs получил stdin /dev/null" \
  || bad "$(grep 'stdin-bad' "$FAKE_LOG" | head -1)"
grep -q "найдено: ntfs" "$SB/out.txt" && ok "найденная сигнатура названа" || bad "нет сообщения о сигнатуре"
[ "$(cat "$FAKE_STATE/sig" 2>/dev/null)" != ntfs ] && ok "сигнатуры NTFS в разделе нет" \
  || bad "сигнатура NTFS осталась"
[ -f "$FAKE_MOUNT/.storage-size-gib" ] && ok "маркер записан" || bad "маркера нет"

# =============================================================================
head_ "S15. setup-ssd-storage.sh: сигнатур нет — wipefs не вызывается"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -5 "$SB/out.txt"; }
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 0 ] && ok "стирание не выполнялось" \
  || bad "wipefs -a вызван: $(grep '^wipefs -a' "$FAKE_LOG" | head -2)"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 1 ] && ok "mkfs.ext4 один раз" || bad "mkfs.ext4 не один раз"
grep -q "wipefs не требуется" "$SB/out.txt" && ok "причина названа" || bad "нет пояснения"
[ ! -f "$FAKE_STATE/mkfs_stdin_bad" ] && ok "mkfs получил stdin /dev/null" || bad "stdin не /dev/null"

# =============================================================================
head_ "S16. setup-ssd-storage.sh: wipefs не убрал сигнатуру — отказ до mkfs"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 FAKE_WIPEFS_KEEP=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск продолжен"
printf '%s' "$out" | grep -q "остались подписи" && ok "причина названа" || bad "нет сообщения"
printf '%s' "$out" | grep -q "обязан быть" && ok "объяснено требование неинтерактивности" || bad "нет пояснения"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнялся" || bad "mkfs выполнен"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" || bad "fstab изменён"
[ ! -f "$FAKE_STATE/mounted" ] && ok "монтирования не было" || bad "смонтировано"

# =============================================================================
head_ "S17. setup-ssd-storage.sh: wipefs вернул ошибку — отказ"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 FAKE_WIPEFS_FAIL=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "ошибка не замечена"
printf '%s' "$out" | grep -q "wipefs не удался" && ok "причина названа" || bad "нет сообщения"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнялся" || bad "mkfs выполнен"

# =============================================================================
head_ "S18. setup-ssd-storage.sh: раздел открыт процессом — отказ"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 FAKE_FUSER_BUSY=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск разрешён"
printf '%s' "$out" | grep -q "открыт процессом" && ok "причина названа" || bad "нет сообщения"
printf '%s' "$out" | grep -q "4242" && ok "PID назван" || bad "PID не назван"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 0 ] && ok "стирание не выполнялось" || bad "wipefs -a выполнен"

# =============================================================================
head_ "S19. setup-ssd-storage.sh: другой серийный номер — отказ до wipefs"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 FAKE_SERIAL=9999WRONG "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск разрешён"
printf '%s' "$out" | grep -q "серийный" && ok "причина названа" || bad "нет сообщения"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 0 ] && ok "стирание не выполнялось" || bad "wipefs -a выполнен"

# =============================================================================
head_ "S20. setup-ssd-storage.sh: раздел не принадлежит диску — отказ"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
export FAKE_PTTYPE=gpt FAKE_PARTTYPE=0fc63daf-8483-4772-8e79-3d69d8477de4
export FAKE_PARTLABEL=VIDEO_STUDIO
: > "$SB/dev/real1"
: > "${FAKE_DEV}-part1"          # обычный файл, а не узел раздела на том же диске
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск разрешён"
printf '%s' "$out" | grep -q "не принадлежит" && ok "причина названа" || bad "нет сообщения"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 0 ] && ok "стирание не выполнялось" || bad "wipefs -a выполнен по чужому узлу"

# =============================================================================
head_ "S21. setup-ssd-storage.sh: mkfs отказал — откат без повторного форматирования"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
out=$(FAKE_ROOT=1 FAKE_MKFS_FAIL=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "ошибка не замечена"
printf '%s' "$out" | grep -q "mkfs.ext4 отказал" && ok "причина названа" || bad "нет сообщения"
printf '%s' "$out" | grep -q "Повторного форматирования не было" && ok "сказано про повтор" || bad "нет пояснения"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 1 ] && ok "mkfs вызван один раз" \
  || bad "mkfs вызван $(grep -c '^mkfs.ext4' "$FAKE_LOG") раз"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" || bad "fstab изменён"
[ ! -f "$FAKE_STATE/mounted" ] && ok "монтирования не было" || bad "смонтировано"
[ ! -f "$FAKE_MOUNT/.storage-size-gib" ] && ok "маркер не записан" || bad "маркер записан"

# =============================================================================
head_ "S22. setup-ssd-storage.sh: продолжение после сбоя — ext4 уже есть"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ext4 > "$FAKE_STATE/sig"
echo "aaaa-bbbb-cccc" > "$FAKE_STATE/uuid"
out=$(FAKE_ROOT=1 FAKE_LABEL=VIDEO_STUDIO "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -6 "$SB/out.txt"; }
[ "$(grep -c '^sgdisk' "$FAKE_LOG")" = 0 ] && ok "разметка не пересоздавалась" || bad "sgdisk вызван"
[ "$(grep -c '^wipefs' "$FAKE_LOG")" = 0 ] && ok "wipefs не вызывался" || bad "wipefs вызван"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "повторного форматирования нет" || bad "mkfs вызван"
grep -q "форматирование не повторяется" "$SB/out.txt" && ok "сказано, что формат пропущен" || bad "нет пояснения"
[ "$(grep -c '^mount ' "$FAKE_LOG")" = 1 ] && ok "mount выполнен" || bad "mount не выполнен"
grep -q "UUID=aaaa-bbbb-cccc $FAKE_MOUNT" "$FAKE_FSTAB" && ok "в fstab записан существующий UUID" \
  || bad "fstab: $(tail -1 "$FAKE_FSTAB")"
[ -f "$FAKE_MOUNT/.storage-size-gib" ] && ok "маркер записан" || bad "маркера нет"

# =============================================================================
head_ "S23. setup-ssd-storage.sh: геометрия не совпала — отказ без правки"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
export FAKE_PART_START=4096
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск разрешён"
printf '%s' "$out" | grep -q "не совпадает с ожидаемой" && ok "причина названа" || bad "нет сообщения"
printf '%s' "$out" | grep -q "начало '4096'" && ok "фактическое значение показано" || bad "нет фактических значений"
[ ! -s "$FAKE_LOG" ] && ok "ни одной внешней команды" || bad "вызваны: $(head -2 "$FAKE_LOG")"

# =============================================================================
head_ "S24. setup-ssd-storage.sh: раздел смонтирован — отказ до стирания"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 FAKE_MOUNTED=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "запуск разрешён"
printf '%s' "$out" | grep -q "смонтировано" && ok "причина названа" || bad "нет сообщения"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 0 ] && ok "стирание не выполнялось" || bad "wipefs -a выполнен"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнялся" || bad "mkfs выполнен"

# =============================================================================
head_ "S25. setup-ssd-storage.sh: примерка на частично созданной разметке"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$("$SB/host/setup-ssd-storage.sh" 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || bad "код $rc"
[ "$(exec_lines "$SB/out.txt")" = 0 ] && ok "ни одной исполненной команды" \
  || bad "в примере есть исполнение: $(grep '^+ ' "$SB/out.txt" | head -2)"
[ ! -s "$FAKE_LOG" ] && ok "внешние команды не вызваны" || bad "вызваны: $(head -2 "$FAKE_LOG")"
grep -q "разметка уже создана предыдущей попыткой" "$SB/out.txt" \
  && ok "разметка узнана" || bad "разметка не узнана"
grep -q '^  sgdisk --zap-all' "$SB/out.txt" && bad "в плане повторный sgdisk --zap-all" \
  || ok "повторного sgdisk в плане нет"
grep -qF "wipefs -a" "$SB/out.txt" && ok "в плане есть стирание подписей" || bad "в плане нет wipefs"
grep -qF "stdin от /dev/null" "$SB/out.txt" && ok "в плане видно неинтерактивность" || bad "нет пометки stdin"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" || bad "fstab изменён"

# =============================================================================
head_ "S26. setup-ssd-storage.sh: подпись видит только wipefs, blkid пуст"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo dos > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 FAKE_BLKID_DOS_ONLY=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -6 "$SB/out.txt"; }
grep -q "найдено: dos" "$SB/out.txt" && ok "подпись dos найдена по wipefs" || bad "подпись не найдена"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 1 ] && ok "стирание выполнено" || bad "стирание не выполнено"

# =============================================================================
head_ "S27. setup-ssd-storage.sh: wipefs -n отказал — чистым не считается"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
out=$(FAKE_ROOT=1 FAKE_WIPEFS_PROBE_FAIL=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "ошибка пробы не замечена"
printf '%s' "$out" | grep -q "wipefs -n завершился с кодом 1" && ok "код возврата назван" || bad "нет кода возврата"
printf '%s' "$out" | grep -q "Считать раздел чистым" && ok "сказано, что чистым не считается" || bad "нет пояснения"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 0 ] && ok "стирание не выполнялось" || bad "wipefs -a вызван"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнялся" || bad "mkfs вызван"

# =============================================================================
head_ "S28. setup-ssd-storage.sh: blkid отказал с непонятным кодом без stderr"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
out=$(FAKE_ROOT=1 FAKE_BLKID_FAIL_NOSTDERR=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "отказ blkid не замечен"
printf '%s' "$out" | grep -q "blkid -p завершился с кодом 4" && ok "код назван" || bad "нет кода"
[ "$(grep -c '^wipefs -a' "$FAKE_LOG")" = 0 ] && ok "стирание не выполнялось" || bad "wipefs -a вызван"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнялся" || bad "mkfs вызван"

# =============================================================================
head_ "S29. setup-ssd-storage.sh: blkid не смог прочитать раздел"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
out=$(FAKE_ROOT=1 FAKE_BLKID_DENIED=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "ошибка чтения не замечена"
printf '%s' "$out" | grep -q "Permission denied" && ok "причина названа" || bad "нет сообщения"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнялся" || bad "mkfs вызван"

# =============================================================================
head_ "S30. setup-ssd-storage.sh: столбцы wipefs заданы явно"
setup_env
cp "$SRC/host/setup-ssd-storage.sh" "$SB/host/"
patch_ssd "$SB/host/setup-ssd-storage.sh"
make_expected_layout
echo ntfs > "$FAKE_STATE/sig"
out=$(FAKE_ROOT=1 "$SB/host/setup-ssd-storage.sh" --apply --confirm-serial 24257G400264 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || bad "код $rc"
probe_line=$(grep -m1 '^wipefs --no-act' "$FAKE_LOG")
[ -n "$probe_line" ] && ok "проба вызвана с --no-act" || bad "проба не найдена в журнале"
case "$probe_line" in
  *"--output TYPE"*) ok "столбец TYPE задан явно" ;;
  *) bad "столбец не задан: $probe_line" ;;
esac
case "$probe_line" in
  *"--noheadings"*) ok "заголовок отключён" ;;
  *) bad "нет --noheadings: $probe_line" ;;
esac

# =============================================================================
head_ "S31. probe_signatures на настоящих wipefs и blkid"
setup_env
if ! command -v wipefs >/dev/null 2>&1 || ! command -v blkid >/dev/null 2>&1; then
  ok "пропущено: wipefs или blkid не установлены"
else
  awk '/^assert_part_readable\(\)/{f=1} f{print} f&&/^}$/{n++; if(n==2) exit}' \
    "$SRC/host/setup-ssd-storage.sh" > "$SB/funcs.sh"
  cat > "$SB/real-probe.sh" <<'EOF'
#!/bin/bash
set -u
. "$1"
die() { echo "ОТКАЗ: $*" >&2; exit 1; }
probe_signatures "$2"
EOF
  truncate -s 2M "$SB/blank.img"
  truncate -s 2M "$SB/dos.img"
  truncate -s 2M "$SB/luks.img"
  printf '\x55\xaa' | dd of="$SB/dos.img" bs=1 seek=510 conv=notrunc status=none 2>/dev/null
  printf 'LUKS\xba\xbe' | dd of="$SB/luks.img" bs=1 conv=notrunc status=none 2>/dev/null
  real_path="/usr/sbin:/usr/bin:/sbin:/bin"
  got=$(PATH="$real_path" bash "$SB/real-probe.sh" "$SB/funcs.sh" "$SB/blank.img" 2>&1)
  [ -z "$got" ] && ok "пустой файл: сигнатур нет" || bad "пустой файл: [$got]"
  got=$(PATH="$real_path" bash "$SB/real-probe.sh" "$SB/funcs.sh" "$SB/dos.img" 2>&1)
  [ "$got" = "dos" ] && ok "DOS/MBR найден настоящим wipefs" || bad "DOS/MBR: [$got]"
  got=$(PATH="$real_path" bash "$SB/real-probe.sh" "$SB/funcs.sh" "$SB/luks.img" 2>&1)
  [ "$got" = "crypto_LUKS" ] && ok "crypto_LUKS найден" || bad "crypto_LUKS: [$got]"
  chmod 000 "$SB/blank.img"
  got=$(PATH="$real_path" bash "$SB/real-probe.sh" "$SB/funcs.sh" "$SB/blank.img" 2>&1); rc=$?
  chmod 644 "$SB/blank.img"
  [ "$rc" != 0 ] && ok "нет прав на чтение — отказ" || bad "нечитаемый файл принят за чистый"
  got=$(PATH="$real_path" bash "$SB/real-probe.sh" "$SB/funcs.sh" "$SB/nosuch.img" 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "файла нет — отказ" || bad "отсутствующий файл принят за чистый"
fi

# =============================================================================
head_ "L1. setup-storage.sh: примерка ничего не исполняет"
setup_env
cp "$SRC/host/setup-storage.sh" "$SB/host/"
patch_loop "$SB/host/setup-storage.sh"
out=$(FAKE_ROOT=1 "$SB/host/setup-storage.sh" 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || bad "код $rc"
[ "$(exec_lines "$SB/out.txt")" = 0 ] && ok "ни одной исполненной команды" \
  || bad "исполнение в примере: $(grep '^+ ' "$SB/out.txt" | head -3)"
[ ! -e "$FAKE_IMAGE" ] && ok "образ не создан" || bad "образ создан в примере"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab не изменён" || bad "fstab изменён"
[ ! -s "$FAKE_LOG" ] && ok "внешние команды не вызваны" || bad "вызваны: $(head -2 "$FAKE_LOG")"

# =============================================================================
head_ "L2. setup-storage.sh: --apply на подставном образе"
setup_env
cp "$SRC/host/setup-storage.sh" "$SB/host/"
patch_loop "$SB/host/setup-storage.sh"
# fallocate получает путь образа: подставная версия создаёт разреженный файл.
cat > "$SB/bin/fallocate" <<'EOF'
#!/bin/sh
echo "fallocate $*" >> "$FAKE_LOG"
sz=""; img=""
while [ $# -gt 0 ]; do
  case "$1" in -l) sz="$2"; shift ;; *) img="$1" ;; esac
  shift
done
truncate -s "${sz%G}G" "$img"
exit 0
EOF
chmod +x "$SB/bin/fallocate"
out=$(FAKE_ROOT=1 FAKE_HOST_FREE_GIB=500 "$SB/host/setup-storage.sh" --apply 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -6 "$SB/out.txt"; }
[ "$(grep -c '^fallocate' "$FAKE_LOG")" = 1 ] && ok "fallocate ровно один раз" \
  || bad "fallocate: $(grep -c '^fallocate' "$FAKE_LOG") раз"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 1 ] && ok "mkfs.ext4 ровно один раз" \
  || bad "mkfs.ext4: $(grep -c '^mkfs.ext4' "$FAKE_LOG") раз (двойное форматирование)"
ln_fstab=$(grep -n "ИЗМЕНЕНО" "$SB/out.txt" | cut -d: -f1)
ln_mount=$(grep -n '^+ mount' "$SB/out.txt" | cut -d: -f1)
[ -n "$ln_fstab" ] && [ -n "$ln_mount" ] && [ "$ln_fstab" -lt "$ln_mount" ] \
  && ok "fstab записан до mount ($ln_fstab < $ln_mount)" || bad "порядок: fstab=$ln_fstab mount=$ln_mount"
[ "$(wc -l < "$FAKE_FSTAB")" = 4 ] && ok "в fstab одна новая строка" || bad "fstab: $(wc -l < "$FAKE_FSTAB")"
[ -f "$FAKE_MOUNT/.storage-size-gib" ] && ok "маркер записан" || bad "маркера нет"
rm -f "$FAKE_IMAGE"

# =============================================================================
head_ "L3. setup-storage.sh: повторный запуск не форматирует снова"
setup_env
cp "$SRC/host/setup-storage.sh" "$SB/host/"
patch_loop "$SB/host/setup-storage.sh"
: > "$FAKE_IMAGE"
cp "$FAKE_LOG" "$SB/log.before"
out=$(FAKE_ROOT=1 "$SB/host/setup-storage.sh" --apply 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc: повторный образ не перезаписан" || bad "перезапись разрешена"
printf '%s' "$out" | grep -q "уже существует" && ok "причина названа" || bad "нет сообщения"
[ "$(grep -c '^mkfs.ext4' "$FAKE_LOG")" = 0 ] && ok "mkfs не выполнен" || bad "mkfs выполнен повторно"

# =============================================================================
head_ "L4. setup-storage.sh: подмена IMAGE/MOUNT через окружение"
setup_env
cp "$SRC/host/setup-storage.sh" "$SB/host/"
patch_loop "$SB/host/setup-storage.sh"
out=$(IMAGE=/tmp/vs-evil.img MOUNT=/tmp/vs-evil-mnt FSTAB=/tmp/vs-evil-fstab \
      FAKE_ROOT=1 FAKE_HOST_FREE_GIB=500 "$SB/host/setup-storage.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || bad "код $rc"
[ ! -e /tmp/vs-evil.img ] && ok "IMAGE из среды не принят" || { bad "создан /tmp/vs-evil.img"; rm -f /tmp/vs-evil.img; }
printf '%s' "$out" | grep -qF "$FAKE_IMAGE" && ok "использован зашитый путь образа" || bad "путь подменён"
[ ! -e /tmp/vs-evil-fstab ] && ok "FSTAB из среды не принят" || { bad "создан /tmp/vs-evil-fstab"; rm -f /tmp/vs-evil-fstab; }

# =============================================================================
head_ "L4b. setup-storage.sh: точки монтирования нет — создаётся до mount"
setup_env
rmdir "$FAKE_MOUNT"
cp "$SRC/host/setup-storage.sh" "$SB/host/"
patch_loop "$SB/host/setup-storage.sh"
out=$(FAKE_ROOT=1 FAKE_HOST_FREE_GIB=500 "$SB/host/setup-storage.sh" --apply 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; printf '%s\n' "$out" | tail -4; }
[ -d "$FAKE_MOUNT" ] && ok "точка монтирования создана" || bad "каталога $FAKE_MOUNT нет"
[ "$(grep -c '^mount ' "$FAKE_LOG")" = 1 ] && ok "mount выполнен один раз" \
  || bad "mount: $(grep -c '^mount ' "$FAKE_LOG") раз"
ln_mkdir=$(grep -n '^+ создать точку монтирования' <<<"$out" | cut -d: -f1)
ln_fstab=$(grep -n '^+ добавить строку' <<<"$out" | cut -d: -f1)
ln_mount=$(grep -n '^+ mount' <<<"$out" | cut -d: -f1)
[ -n "$ln_mkdir" ] && [ -n "$ln_fstab" ] && [ "$ln_mkdir" -lt "$ln_fstab" ] \
  && ok "каталог создан до записи fstab (строки $ln_mkdir < $ln_fstab)" \
  || bad "порядок нарушен: каталог=$ln_mkdir fstab=$ln_fstab"

# =============================================================================
head_ "L5. setup-storage.sh: отказ mount — образ удалён, fstab восстановлен"
setup_env
cp "$SRC/host/setup-storage.sh" "$SB/host/"
patch_loop "$SB/host/setup-storage.sh"
cat > "$SB/bin/fallocate" <<'EOF'
#!/bin/sh
sz=""; img=""
while [ $# -gt 0 ]; do
  case "$1" in -l) sz="$2"; shift ;; *) img="$1" ;; esac
  shift
done
truncate -s "${sz%G}G" "$img"
exit 0
EOF
chmod +x "$SB/bin/fallocate"
out=$(FAKE_ROOT=1 FAKE_MOUNT_FAIL=1 FAKE_HOST_FREE_GIB=500 "$SB/host/setup-storage.sh" --apply 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "ошибка не замечена"
printf '%s' "$out" | grep -q "Откат после ошибки" && ok "откат выполнен" || bad "отката нет"
cmp -s "$FAKE_FSTAB" "$SB/fstab.orig" && ok "fstab восстановлен" || bad "fstab не восстановлен"
[ ! -e "$FAKE_IMAGE" ] && ok "образ удалён (не смонтирован, удалять безопасно)" || bad "образ остался"
printf '%s' "$out" | grep -q "Удаляю созданный образ" && ok "удаление объявлено" || bad "нет сообщения"

# =============================================================================
head_ "R1. remove-storage.sh: примерка ничего не исполняет"
setup_env
cp "$SRC/host/remove-storage.sh" "$SB/host/"
patch_remove "$SB/host/remove-storage.sh"
printf 'UUID=x %s ext4 defaults,nofail 0 2\n' "$FAKE_MOUNT" >> "$FAKE_FSTAB"
cp "$FAKE_FSTAB" "$SB/fstab.before"
out=$(FAKE_ROOT=1 FAKE_MOUNTED=1 "$SB/host/remove-storage.sh" 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || bad "код $rc"
[ "$(exec_lines "$SB/out.txt")" = 0 ] && ok "ни одной исполненной команды" \
  || bad "исполнение в примере: $(grep '^+ ' "$SB/out.txt")"
[ ! -s "$FAKE_LOG" ] && ok "umount и docker не вызывались" || bad "вызваны: $(head -2 "$FAKE_LOG")"
cmp -s "$FAKE_FSTAB" "$SB/fstab.before" && ok "fstab не изменён" || bad "fstab изменён"
[ -d "$FAKE_MOUNT" ] && ok "точка монтирования не тронута" || bad "каталог удалён"

# =============================================================================
head_ "R2. remove-storage.sh: --apply снимает монтирование и строку fstab"
setup_env
cp "$SRC/host/remove-storage.sh" "$SB/host/"
patch_remove "$SB/host/remove-storage.sh"
printf 'UUID=x %s ext4 defaults,nofail 0 2\n' "$FAKE_MOUNT" >> "$FAKE_FSTAB"
touch "$FAKE_STATE/mounted"
out=$(FAKE_ROOT=1 "$SB/host/remove-storage.sh" --apply 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -4 "$SB/out.txt"; }
[ "$(grep -c '^umount' "$FAKE_LOG")" = 1 ] && ok "umount ровно один раз" \
  || bad "umount: $(grep -c '^umount' "$FAKE_LOG")"
[ "$(wc -l < "$FAKE_FSTAB")" = 3 ] && ok "строка удалена, остальные целы" \
  || bad "fstab: $(wc -l < "$FAKE_FSTAB") строк"
grep -q "$FAKE_MOUNT" "$FAKE_FSTAB" && bad "строка осталась" || ok "записи для точки нет"
ls "$SB"/fstab.bak-* >/dev/null 2>&1 && ok "резервная копия fstab создана" || bad "копии нет"
out2=$(FAKE_ROOT=1 "$SB/host/remove-storage.sh" --apply 2>&1); rc2=$?
[ "$rc2" = 0 ] && ok "повторный запуск: код 0" || bad "повторный: код $rc2"
printf '%s' "$out2" | grep -q "УЖЕ ОТКЛЮЧЕНО" && ok "повторный запуск ничего не делает" \
  || bad "нет сообщения о повторном запуске"
[ "$(grep -c '^umount' "$FAKE_LOG")" = 1 ] && ok "повторного umount нет" \
  || bad "повторный umount выполнен"

# =============================================================================
head_ "R3. remove-storage.sh: --delete-image для раздела запрещён"
setup_env
cp "$SRC/host/remove-storage.sh" "$SB/host/"
patch_remove "$SB/host/remove-storage.sh"
touch "$FAKE_STATE/mounted"
out=$(FAKE_ROOT=1 FAKE_MOUNTED=1 FAKE_SOURCE=/dev/fake-sda2 "$SB/host/remove-storage.sh" --apply --delete-image 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "удаление разрешено"
printf '%s' "$out" | grep -q "запрещён: устройство не стирается" && ok "причина названа" \
  || bad "нет сообщения"
[ ! -s "$FAKE_LOG" ] && ok "ничего не выполнено" || bad "вызваны: $(head -2 "$FAKE_LOG")"

# =============================================================================
head_ "R4. remove-storage.sh: символьная ссылка вместо образа не удаляется"
setup_env
cp "$SRC/host/remove-storage.sh" "$SB/host/"
patch_remove "$SB/host/remove-storage.sh"
: > "$SB/target-file"
ln -sf "$SB/target-file" "$FAKE_IMAGE"
out=$(FAKE_ROOT=1 "$SB/host/remove-storage.sh" --apply --delete-image 2>&1); rc=$?
[ -L "$FAKE_IMAGE" ] && ok "ссылка не удалена" || bad "ссылка удалена"
[ -f "$SB/target-file" ] && ok "цель ссылки цела" || bad "цель ссылки удалена"
printf '%s' "$out" | grep -q "ПРОПУЩЕНО" && ok "удаление пропущено осознанно" || bad "нет сообщения"

# =============================================================================
head_ "R5. resize-storage.sh: примерка ничего не исполняет"
setup_env
cp "$SRC/host/resize-storage.sh" "$SB/host/"
patch_resize "$SB/host/resize-storage.sh"
: > "$FAKE_IMAGE"
out=$(FAKE_ROOT=1 FAKE_MOUNTED=1 FAKE_SOURCE=/dev/loop7 FAKE_TOTAL_KI=41943040 \
      "$SB/host/resize-storage.sh" --size-gib 60 2>&1); rc=$?
printf '%s' "$out" > "$SB/out.txt"
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; tail -4 "$SB/out.txt"; }
[ "$(exec_lines "$SB/out.txt")" = 0 ] && ok "ни одной исполненной команды" \
  || bad "исполнение в примере: $(grep '^+ ' "$SB/out.txt")"
[ ! -s "$FAKE_LOG" ] && ok "truncate и resize2fs не вызывались" || bad "вызваны: $(head -2 "$FAKE_LOG")"

# =============================================================================
head_ "R6. resize-storage.sh: нечисловой размер отклонён"
setup_env
cp "$SRC/host/resize-storage.sh" "$SB/host/"
patch_resize "$SB/host/resize-storage.sh"
for bad_size in abc "60; rm -rf /" -5 "" 99999; do
  out=$(FAKE_ROOT=1 FAKE_MOUNTED=1 FAKE_SOURCE=/dev/loop7 "$SB/host/resize-storage.sh" --size-gib "$bad_size" 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "размер '$bad_size' отклонён (код $rc)" || bad "размер '$bad_size' принят"
done
[ ! -s "$FAKE_LOG" ] && ok "ничего не выполнено" || bad "вызваны команды"

# =============================================================================
head_ "R7. resize-storage.sh: тот же размер — не ошибка"
setup_env
cp "$SRC/host/resize-storage.sh" "$SB/host/"
patch_resize "$SB/host/resize-storage.sh"
: > "$FAKE_IMAGE"
out=$(FAKE_ROOT=1 FAKE_MOUNTED=1 FAKE_SOURCE=/dev/loop7 FAKE_TOTAL_KI=41943040 \
      "$SB/host/resize-storage.sh" --apply --size-gib 40 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || bad "код $rc"
printf '%s' "$out" | grep -q "УЖЕ ТАКОЙ РАЗМЕР" && ok "изменений не требуется" || bad "нет сообщения"
[ ! -s "$FAKE_LOG" ] && ok "truncate не выполнялся" || bad "выполнены команды"

# =============================================================================
head_ "R8. resize-storage.sh: раздел SSD не расширяется"
setup_env
cp "$SRC/host/resize-storage.sh" "$SB/host/"
patch_resize "$SB/host/resize-storage.sh"
: > "$FAKE_IMAGE"
out=$(FAKE_ROOT=1 FAKE_MOUNTED=1 FAKE_SOURCE=/dev/fake-sda2 FAKE_TOTAL_KI=41943040 \
      "$SB/host/resize-storage.sh" --size-gib 60 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc" || bad "расширение разрешено"
printf '%s' "$out" | grep -q "хранилище на разделе" && ok "варианты названы" || bad "нет сообщения"
[ ! -s "$FAKE_LOG" ] && ok "ничего не выполнено" || bad "вызваны команды"

# =============================================================================
head_ "V1. size-check.sh: границы допуска 1 GiB"
. "$SRC/size-check.sh"
check() { if size_matches "$1" "$2"; then echo yes; else echo no; fi; }
[ "$(check 972029 927)" = no ] && ok "927 GiB против маркера 927 при 972029 KiB — нет" || bad "завышенный размер принят"
[ "$(check $((927*1048576)) 927)" = yes ] && ok "точное совпадение принято" || bad "точное совпадение отклонено"
[ "$(check $((927*1048576+1048576)) 927)" = yes ] && ok "разница ровно 1 GiB принята" || bad "1 GiB отклонён"
[ "$(check $((927*1048576+1048577)) 927)" = no ] && ok "разница больше 1 GiB отклонена" || bad "2 GiB приняты"
[ "$(check $((935*1048576)) 927)" = no ] && ok "935 GiB против маркера 927 отклонено" || bad "935 принят"
[ "$(check $((40*1048576)) 927)" = no ] && ok "40 GiB против маркера 927 отклонено" || bad "40 принят"
[ "$(check '' 40)" = no ] && ok "пустой размер отклонён" || bad "пустой размер принят"
[ "$(check abc 40)" = no ] && ok "нечисловой размер отклонён" || bad "мусор принят"
[ "$(check 41943040 '')" = no ] && ok "пустой маркер отклонён" || bad "пустой маркер принят"

# =============================================================================
head_ "V2. verify-storage.sh: --fill на рабочем хранилище запрещён"
setup_env
seed_verify_env 40 41943040 "$FAKE_MOUNT"
out=$(MIN_GIB=38 "$SB/scripts/verify-storage.sh" --fill 2>&1); rc=$?
[ "$rc" = 2 ] && ok "код 2" || { bad "код $rc"; printf '%s\n' "$out" | tail -4; }
printf '%s' "$out" | grep -q "запрещён на рабочем хранилище" && ok "причина названа" || bad "нет сообщения"

# =============================================================================
head_ "V3. verify-storage.sh: --fill запрещён на большом хранилище"
setup_env
seed_verify_env 40 41943040 /nonexistent
out=$(MIN_GIB=38 "$SB/scripts/verify-storage.sh" --fill 2>&1); rc=$?
[ "$rc" = 2 ] && ok "код 2" || { bad "код $rc"; printf '%s\n' "$out" | tail -4; }
printf '%s' "$out" | grep -q "больше предела" && ok "причина названа" || bad "нет сообщения"

# =============================================================================
head_ "V4. verify-storage.sh: --fill без явного подтверждения"
setup_env
seed_verify_env 2 2097152 /nonexistent
out=$(MIN_GIB=1 "$SB/scripts/verify-storage.sh" --fill 2>&1); rc=$?
[ "$rc" = 2 ] && ok "код 2" || { bad "код $rc"; printf '%s\n' "$out" | tail -4; }
printf '%s' "$out" | grep -q "требует явного подтверждения" && ok "причина названа" || bad "нет сообщения"

# =============================================================================
head_ "V5. verify-storage.sh: --fill на маленьком тестовом хранилище проходит ворота"
setup_env
seed_verify_env 2 2097152 /nonexistent
: > "$FAKE_MOUNT/.fill-test-ok"
out=$(MIN_GIB=1 "$SB/scripts/verify-storage.sh" --fill 2>&1); rc=$?
printf '%s' "$out" | grep -q "на месте" && ok "ворота пройдены" || bad "ворота не пройдены"
printf '%s' "$out" | grep -q "запрещён" && bad "ложный отказ" || ok "отказа нет"

# =============================================================================
head_ "V5b. verify-storage.sh: без --fill ворота не запрашиваются"
setup_env
seed_verify_env 2 2097152 /nonexistent
out=$(MIN_GIB=1 "$SB/scripts/verify-storage.sh" 2>&1); rc=$?
printf '%s' "$out" | grep -q "Допуск режима --fill" && bad "ворота --fill запускались без флага" \
  || ok "без --fill проверки допуска не выполняются"

# =============================================================================
head_ "V6. verify-storage.sh: сверка размера тем же модулем, что в ограде"
grep -q 'size_matches' "$SRC/scripts/verify-storage.sh" && ok "verify-storage использует size_matches" || bad "своя сверка"
grep -q 'size_matches' "$SRC/guard.sh" && ok "guard.sh использует size_matches" || bad "своя сверка в ограде"
grep -q 'SIZE_CHECK_LIB' "$SRC/guard.sh" && ok "guard.sh подключает общий модуль" || bad "модуль не подключён"
grep -c '1048576' "$SRC/scripts/verify-storage.sh" >/dev/null && ok "процентного допуска в verify нет" || true
grep -q '95 / 100\|105 / 100' "$SRC/scripts/verify-storage.sh" && bad "в verify остался процентный допуск" || ok "процентного допуска нет"
[ "$(grep -c 'size_matches' "$SRC/host/setup-ssd-storage.sh")" -ge 1 ] && ok "установочный скрипт тоже сверяет через модуль" || bad "нет сверки"

# =============================================================================
printf '\n=== ИТОГ: ПРОЙДЕНО %s, НЕ ПРОЙДЕНО %s ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
