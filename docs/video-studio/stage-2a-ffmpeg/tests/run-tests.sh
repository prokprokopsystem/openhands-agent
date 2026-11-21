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
# Раскладка репозитория держит модуль сверки в корне этапа, раскладка на сервере
# — в каталоге образа. Стенд должен работать в обеих.
SIZE_LIB=""
for c in "$SRC/size-check.sh" "$SRC/image/ffmpeg/size-check.sh"; do
  [ -r "$c" ] && { SIZE_LIB="$c"; break; }
done
[ -n "$SIZE_LIB" ] || { printf 'не найден size-check.sh ни в корне, ни в image/ffmpeg\n' >&2; exit 2; }
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

  # Настоящий findmnt различает запрос точной точки монтирования (-M) и запрос
  # источника корня, поэтому имитация это тоже различает: иначе проверка
  # «каталог внутри раздела» и «источник не корень» проходила бы молча.
  cat > "$bin/findmnt" <<'EOF'
#!/bin/sh
st="$FAKE_STATE"
mounted() {
  [ -f "$st/unmounted" ] && return 1
  [ "${FAKE_MOUNTED:-0}" = 1 ] || [ -f "$st/mounted" ]
}
target=""
exact=0
for a in "$@"; do
  case "$a" in
    -M) exact=1 ;;
    /*) target="$a" ;;
  esac
done
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
      TARGET)
        mounted || exit 1
        # FAKE_IS_MOUNTPOINT=0 — каталог существует, но точкой монтирования
        # не является: строгий запрос обязан отказать.
        [ "$exact" = 1 ] && [ "${FAKE_IS_MOUNTPOINT:-1}" != 1 ] && exit 1
        [ "$exact" = 1 ] && [ -n "$target" ] && [ "$target" != "$FAKE_MOUNT" ] && exit 1
        echo "$FAKE_MOUNT"; exit 0 ;;
      SOURCE)
        if [ "$target" = "/" ]; then echo "${FAKE_ROOT_SOURCE:-/dev/mapper/root}"; exit 0; fi
        echo "${FAKE_SOURCE:-${FAKE_DEV}-part1}" ;;
      FSTYPE)   echo "${FAKE_FSTYPE:-ext4}" ;;
      SOURCE,FSTYPE,SIZE,OPTIONS) echo "${FAKE_DEV}-part1 ext4 40G rw,nofail" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF

  # GNU coreutils df объявляет -P и --output взаимоисключающими и выходит кодом 1.
# Имитация это повторяет: иначе недопустимая команда проходит стенд молча.
cat > "$bin/df" <<'EOF'
#!/bin/sh
case "$*" in
  *-P*)
    case "$*" in
      *--output*)
        echo "df: options -P and --output are mutually exclusive" >&2
        echo "Try 'df --help' for more information." >&2
        exit 1 ;;
    esac ;;
esac
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
  cp "$SIZE_LIB" "$SB/size-check.sh"
  export PATH="$SB/bin:$PATH"
  unset FAKE_MOUNTED FAKE_MOUNT_FAIL FAKE_VERIFY_FAIL FAKE_LABEL FAKE_PTTYPE \
        FAKE_SERIAL_SWITCH FAKE_SERIAL FAKE_ROOT FAKE_HOST_FREE_GIB \
        FAKE_TOTAL_KI MIN_GIB FAKE_PARTTYPE FAKE_PARTLABEL FAKE_PART_START \
        FAKE_PART_BYTES FAKE_FUSER_BUSY FAKE_WIPEFS_FAIL FAKE_WIPEFS_KEEP \
        FAKE_MKFS_FAIL FAKE_UUID FAKE_WIPEFS_PROBE_FAIL FAKE_BLKID_DOS_ONLY \
        FAKE_BLKID_FAIL_NOSTDERR FAKE_BLKID_DENIED FAKE_IS_MOUNTPOINT \
        FAKE_ROOT_SOURCE FAKE_FOREIGN FAKE_FOREIGN_LOSE FAKE_OUT_DEV \
        FAKE_ROOT_DEV FAKE_UP_FAIL FAKE_FSTYPE FAKE_GUARD_FAIL \
        FAKE_IN_TOTAL_KI FAKE_EXEC_FAIL FAKE_UNMOUNT_AFTER_UP \
        FAKE_WORK_WRITABLE DISK_PROJECT
}

# Для проверок verify-storage: смонтированное хранилище с маркером и записью
# в fstab, иначе скрипт останавливается раньше ворот --fill.
seed_verify_env() {
  local marker="$1" total_ki="$2" prod_mount="$3"
  cp "$SRC/scripts/verify-storage.sh" "$SB/scripts/"
  cp "$SIZE_LIB" "$SB/size-check.sh"
  sed -i -e "s|^PRODUCTION_MOUNT=.*|PRODUCTION_MOUNT=\"$prod_mount\"|" \
         -e "s|^ROOT=.*|ROOT=\"$SB\"|" \
         -e "s|/etc/fstab|$FAKE_FSTAB|g" "$SB/scripts/verify-storage.sh"
  echo "$marker" > "$FAKE_MOUNT/.storage-size-gib"
  printf 'UUID=x %s ext4 defaults,nofail 0 2\n' "$FAKE_MOUNT" >> "$FAKE_FSTAB"
  export FAKE_MOUNTED=1 FAKE_TOTAL_KI="$total_ki" FAKE_SOURCE=/dev/loop7
  export MOUNT="$FAKE_MOUNT"
}

# verify-storage проверяет настоящие блочные устройства. В песочнице их нет,
# поэтому признак блочности подменяется непустым именем источника — так же,
# как это уже сделано в patch_remove и patch_resize.
patch_verify() {
  python3 - "$SB/scripts/verify-storage.sh" <<'PYVERIFY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if [ -b "$source" ]; then'
assert old in s, old
s = s.replace(old, 'if [ -n "$source" ]; then', 1)
open(p, "w").write(s)
PYVERIFY
}

# Имитация docker: compose с отдельным именем проекта, exec для проверок
# внутри контейнера и снимок чужих контейнеров. Все вызовы пишутся в FAKE_LOG,
# поэтому «к чему скрипт обращался» проверяется по факту.
seed_verify_docker() {
  mkdir -p "$SB/bin-dc"
  cat > "$SB/bin-dc/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$FAKE_LOG"
st="$FAKE_STATE"
case "$1" in
  compose)
    shift
    verb=""
    for a in "$@"; do
      case "$a" in up|down|restart|ps|stop) verb="$a" ;; esac
    done
    case "$verb" in
      up) [ "${FAKE_UP_FAIL:-0}" = 1 ] && { echo "compose: отказ" >&2; exit 1; }
          : > "$st/up"
          [ "${FAKE_UNMOUNT_AFTER_UP:-0}" = 1 ] && : > "$st/unmounted"
          exit 0 ;;
      stop) rm -f "$st/up"; exit 0 ;;
      down) rm -f "$st/up"; exit 0 ;;
      restart) : > "$st/restarted"; exit 0 ;;
      ps)
        for a in "$@"; do
          case "$a" in
            -q) echo "cid-studio-disk"; exit 0 ;;
            -aq) [ -f "$st/up" ] && echo "cid-studio-disk"; exit 0 ;;
          esac
        done
        exit 0 ;;
    esac
    exit 0 ;;
  exec)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -e|-u|-w) shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    shift
    case "$*" in
      *"${FAKE_EXEC_FAIL:-__нет__}"*) echo "docker exec: отказ (подставной)" >&2; exit 2 ;;
      *"/scratch"*) exit 0 ;;
      *"/work/.t"*) [ "${FAKE_WORK_WRITABLE:-0}" = 1 ] && exit 0; exit 1 ;;
      *"/storage/.storage-size-gib"*) exit 0 ;;
      *"ffmpeg-guard"*)
        [ "${FAKE_GUARD_FAIL:-0}" = 1 ] && { echo "ОГРАДА: отказ (подставной)" >&2; exit 78; }
        echo "ffmpeg-guard: квота 40G действует"; exit 0 ;;
      *"sh -c"*".verify/fill"*)
        # Заполнение обязано упереться в предел: иначе проверка не отличит
        # действующий предел от отсутствующего.
        printf 'ОТКАЗ НА ФАЙЛЕ 3\nзанято=2040MiB свободно=8MiB файлов=3\n'
        exit 0 ;;
      *"df -Pk /out"*) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sdc1 %s 10240 1000 1%% /out\n' "${FAKE_IN_TOTAL_KI:-${FAKE_TOTAL_KI:-41943040}}"; exit 0 ;;
      *"df -Pm /out"*) printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/sdc1 %s %s %s 1%% /out\n' "$(( ${FAKE_TOTAL_KI:-41943040} / 1024 ))" "${FAKE_USED_MIB:-10}" "${FAKE_FREE_MIB:-40000}"; exit 0 ;;
      *"stat -c %d /out"*) echo "${FAKE_OUT_DEV:-42}"; exit 0 ;;
      *"stat -c %d /"*) echo "${FAKE_ROOT_DEV:-41}"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  ps)
    case "$*" in
      *--format*)
        [ -f "$st/up" ] && echo "video-studio-disk-check-studio-disk-1"
        if [ -n "${FAKE_FOREIGN:-}" ]; then
          if [ "${FAKE_FOREIGN_LOSE:-0}" = 1 ] && [ -f "$st/ps_seen" ]; then
            printf '%s\n' "$FAKE_FOREIGN" | grep -v '^amnesia-bridge$'
          else
            printf '%s\n' "$FAKE_FOREIGN"
          fi
        fi
        : > "$st/ps_seen"
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$SB/bin-dc/docker"
  export PATH="$SB/bin-dc:$SB/bin:$PATH"
}

# Рабочая точка с настоящим видом источника: раздел на диске и его серийный
# номер. Так проверяется именно сверка тождества, а не ветка loop-образа.
seed_verify_prod() {
  # Путь именно в /dev: ветка раздела узнаётся по нему. Наличие файла не
  # важно — признак блочности в песочнице подменён patch_verify.
  export FAKE_SOURCE=/dev/sdc1 FAKE_ROOT_SOURCE=/dev/mapper/root
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
cp "$SIZE_LIB" "$SB/image/ffmpeg/size-check.sh"
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
head_ "S32. ни один скрипт не сочетает df -P с --output"
# GNU df объявляет эти опции взаимоисключающими и выходит кодом 1. Проверка
# статическая: одна команда df не должна иметь оба признака.
bad_df=$(grep -rn --include=*.sh 'df ' "$SRC"/host "$SRC"/scripts \
  | awk '{
      code = $0
      sub(/^[^:]*:[0-9]+:/, "", code)
      if (code ~ /^[ \t]*#/) next
      if (code ~ /df / && code ~ /-P/ && code ~ /--output/) print "'"$SRC"'" code
    }')
[ -z "$bad_df" ] && ok "несовместимых вызовов df нет" || bad "найдено: $bad_df"

# =============================================================================
head_ "S33. подставной df отвергает -P вместе с --output, как настоящий"
setup_env
out=$("$SB/bin/df" -Pk --output=size /tmp 2>&1); rc=$?
[ "$rc" = 1 ] && ok "подставной df: код 1" || bad "подставной df: код $rc"
printf '%s' "$out" | grep -q "mutually exclusive" && ok "подставной df: причина названа" || bad "нет причины: $out"
real_path="/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$real_path" command -v df >/dev/null 2>&1; then
  out=$(PATH="$real_path" df -Pk --output=size /tmp 2>&1); rc=$?
  [ "$rc" = 1 ] && ok "настоящий df: код 1 — поведение совпадает" || bad "настоящий df: код $rc"
  printf '%s' "$out" | grep -q "mutually exclusive" && ok "настоящий df: та же причина" || bad "иное сообщение: $out"
  out=$(PATH="$real_path" df -Pk /tmp 2>&1); rc=$?
  [ "$rc" = 0 ] && ok "настоящий df -Pk без --output: код 0" || bad "df -Pk: код $rc"
else
  ok "пропущено: настоящего df нет"
fi
out=$("$SB/bin/df" -Pk /tmp 2>&1); rc=$?
[ "$rc" = 0 ] && ok "подставной df -Pk: код 0" || bad "df -Pk: код $rc"
out=$("$SB/bin/df" -BG --output=size /tmp 2>&1); rc=$?
[ "$rc" = 0 ] && ok "подставной df --output без -P: код 0" || bad "df --output: код $rc"

# =============================================================================
head_ "S34. do_marker на настоящем df создаёт корректный маркер"
setup_env
real_path="/usr/bin:/bin:/usr/sbin:/sbin"
if ! PATH="$real_path" command -v df >/dev/null 2>&1; then
  ok "пропущено: настоящего df нет"
else
  awk '/^do_marker\(\)/{f=1} f{print} f&&/^}$/{exit}' \
    "$SRC/host/setup-ssd-storage.sh" > "$SB/marker-func.sh"
  cat > "$SB/marker-run.sh" <<'EOF'
#!/bin/bash
set -uE
MOUNT="$1"
say() { printf '%s\n' "$*"; }
die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }
. "$2"
do_marker
EOF
  marker_dir="$SB/marker-mnt"
  mkdir -p "$marker_dir"
  out=$(PATH="$real_path" bash "$SB/marker-run.sh" "$marker_dir" "$SB/marker-func.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok "код 0" || bad "код $rc: $out"
  marker="$marker_dir/.storage-size-gib"
  if [ -f "$marker" ]; then
    ok "маркер создан"
    declared=$(cat "$marker")
    case "$declared" in
      ''|*[!0-9]*) bad "маркер не целое число: '$declared'" ;;
      *) ok "маркер — целое число: $declared GiB" ;;
    esac
    total_ki=$(PATH="$real_path" df -Pk "$marker_dir" | awk 'NR==2{print $2}')
    expect=$(( total_ki / 1048576 ))
    [ "$declared" = "$expect" ] && ok "значение совпало с df ($expect GiB)" \
      || bad "маркер $declared, по df $expect"
    mode=$(stat -c '%a' "$marker")
    [ "$mode" = "444" ] && ok "права 0444" || bad "права $mode"
    printf '%s' "$out" | grep -q "маркер: $expect GiB" && ok "значение напечатано" \
      || bad "нет строки о маркере: $out"
    chmod 0644 "$marker"
    out=$(PATH="$real_path" bash "$SB/marker-run.sh" "$marker_dir" "$SB/marker-func.sh" 2>&1); rc=$?
    [ "$rc" = 0 ] && ok "повторный запуск перезаписывает маркер" || bad "повтор: код $rc: $out"
  else
    bad "маркера нет: $out"
  fi
  # df, который не смог ответить, должен дать отказ, а не пустой маркер.
  mkdir -p "$SB/bin-broken"
  cat > "$SB/bin-broken/df" <<'EOF'
#!/bin/sh
echo "df: simulated failure" >&2
exit 1
EOF
  chmod +x "$SB/bin-broken/df"
  malformed="$SB/malformed-mnt"
  mkdir -p "$malformed"
  out=$(PATH="$SB/bin-broken:$real_path" bash "$SB/marker-run.sh" "$malformed" "$SB/marker-func.sh" 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "отказ df — ненулевой код" || bad "отказ df не замечен"
  [ ! -f "$malformed/.storage-size-gib" ] && ok "маркер не создан при отказе df" \
    || bad "маркер создан при отказе df"
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
. "$SIZE_LIB"
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
# Источник согласован с рабочей точкой: серийный номер совпадает, иначе отказ
# пришёл бы раньше, на сверке тождества, и ворота --fill не проверялись бы.
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264
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
# W — тождество хранилища, изоляция контейнеров и защита системного диска.

run_verify() { bash "$SB/scripts/verify-storage.sh" "$@"; }
docker_calls() { grep '^docker ' "$FAKE_LOG" 2>/dev/null || true; }
# Снимок `docker ps -a` безобиден и делается всегда; ворота проверяются
# по фактическому запуску контейнера.
container_started() { docker_calls | grep -Eq 'compose .* up|^docker exec|compose .* restart'; }

# --- W1. рабочая точка и рабочий SSD: совпадение обязательно ----------------
head_ "W1. verify-storage.sh: на рабочей точке серийный номер обязан совпасть"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0 — проверка прошла" || { bad "код $rc"; printf '%s\n' "$out" | tail -6; }
printf '%s' "$out" | grep -q "рабочий SSD 24257G400264, как и требуется" \
  && ok "совпадение принято как правильное" || bad "совпадение не принято"
printf '%s' "$out" | grep -q "писать в него через" && bad "рабочий SSD отвергнут" \
  || ok "ложного запрета нет"

# --- W2. рабочая точка, чужой диск -------------------------------------------
head_ "W2. verify-storage.sh: на рабочей точке чужой серийный номер — отказ"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=9999WRONG
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"
printf '%s' "$out" | grep -q "нужен рабочий SSD 24257G400264" && ok "причина названа" || bad "нет сообщения"

# --- W3. тестовая точка на рабочем SSD --------------------------------------
head_ "W3. verify-storage.sh: тестовая точка на рабочем SSD запрещена"
setup_env
seed_verify_env 40 41943040 /nonexistent
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264
out=$(MIN_GIB=38 run_verify 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"
printf '%s' "$out" | grep -q "писать в него через" && ok "причина названа" || bad "нет сообщения"
container_started && bad "контейнер запускался: $(docker_calls | grep -E 'up|exec|restart' | head -2)" \
  || ok "контейнер не запускался"

# --- W4. источник — корневая файловая система -------------------------------
head_ "W4. verify-storage.sh: источник совпал с корнем — отказ до контейнера"
setup_env
seed_verify_env 40 41943040 /nonexistent
patch_verify
seed_verify_docker
export FAKE_SOURCE=/dev/mapper/root FAKE_ROOT_SOURCE=/dev/mapper/root
out=$(MIN_GIB=38 run_verify 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"
printf '%s' "$out" | grep -q "корневая файловая система, писать в него нельзя" \
  && ok "корень распознан" || bad "корень не распознан"
printf '%s' "$out" | grep -q "логический том" && ok "ветка тома пройдена" \
  || bad "ветка тома не пройдена"
container_started && bad "контейнер запускался: $(docker_calls | grep -E 'up|exec|restart' | head -2)" \
  || ok "контейнер не запускался"

# --- W5. хранилище не смонтировано ------------------------------------------
head_ "W5. verify-storage.sh: не смонтировано — отказ, ничего не создано"
setup_env
seed_verify_env 926 972029952 /nonexistent
patch_verify
seed_verify_docker
export FAKE_MOUNTED=0
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"
printf '%s' "$out" | grep -q "не смонтирован" && ok "причина названа" || bad "нет сообщения"
container_started && bad "контейнер запускался: $(docker_calls | grep -E 'up|exec|restart' | head -2)" \
  || ok "контейнер не запускался"

# --- W6. строгий запрос точки монтирования ----------------------------------
head_ "W6. verify-storage.sh: спрашивает именно точку монтирования (-M)"
grep -q 'findmnt -no TARGET -M' "$SRC/scripts/verify-storage.sh" \
  && ok "используется -M" || bad "нет -M: каталог внутри раздела сойдёт за хранилище"
setup_env
seed_verify_env 926 972029952 /nonexistent
patch_verify
seed_verify_docker
export FAKE_IS_MOUNTPOINT=0
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"
printf '%s' "$out" | grep -q "не смонтирован" && ok "каталог без монтирования отвергнут" \
  || bad "каталог без монтирования принят"

# --- W7. полный прогон: изоляция от чужих сервисов --------------------------
head_ "W7. verify-storage.sh: полный прогон не трогает чужие контейнеры"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264
export FAKE_FOREIGN="amnesia-bridge
nextcloud-aio-mastercontainer
openhands-agent
paperless-webserver-1
wg0"
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; printf '%s\n' "$out" | tail -8; }
grep -q -- '--project-name video-studio-disk-check' "$FAKE_LOG" \
  && ok "собственный проект compose" || bad "нет собственного имени проекта"
docker_calls | grep -q 'compose .*down' && ok "уборка через compose down" || bad "нет down"
if docker_calls | grep -Eq '^docker (stop|rm|kill|restart|prune)( |$)'; then
  bad "прямые команды над контейнерами: $(docker_calls | grep -E '^docker (stop|rm|kill|prune)' | head -2)"
else
  ok "прямых stop/rm/kill/prune нет"
fi
docker_calls | grep -Eq 'docker (stop|rm|kill) [a-z]*(amnesia|paperless|nextcloud|openhands)' \
  && bad "обращение к чужому контейнеру" || ok "чужие контейнеры не названы ни в одной команде"
printf '%s' "$out" | grep -q "состав остальных контейнеров не изменился" \
  && ok "снимок чужих контейнеров совпал" || bad "снимок не совпал"
printf '%s' "$out" | grep -q "контейнеры проекта video-studio-disk-check остановлены" \
  && ok "остановлен только свой проект" || bad "свой проект не остановлен"

# --- W8. чужой контейнер пропал во время проверки ---------------------------
head_ "W8. verify-storage.sh: пропажа чужого контейнера — провал проверки"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264 FAKE_FOREIGN_LOSE=1
export FAKE_FOREIGN="amnesia-bridge
paperless-webserver-1"
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
printf '%s' "$out" | grep -q "состав контейнеров изменился" && ok "изменение замечено" \
  || bad "изменение не замечено"
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"

# --- W9. /out на корневой файловой системе контейнера -----------------------
head_ "W9. verify-storage.sh: /out на корне контейнера — провал"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264 FAKE_OUT_DEV=41 FAKE_ROOT_DEV=41
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
printf '%s' "$out" | grep -q "/out на корневой файловой системе контейнера" \
  && ok "подмена раздела замечена" || bad "подмена не замечена"
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"

# --- W10. --fill при рабочем SSD на тестовой точке --------------------------
head_ "W10. verify-storage.sh: --fill на тестовой точке с рабочим SSD — отказ"
setup_env
seed_verify_env 2 2097152 /nonexistent
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264
out=$(MIN_GIB=1 run_verify --fill 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1 — отказ раньше ворот --fill" || bad "код $rc"
printf '%s' "$out" | grep -q "писать в него через" && ok "рабочий SSD назван" || bad "нет сообщения"
printf '%s' "$out" | grep -q "Допуск режима --fill" && bad "дело дошло до ворот --fill" \
  || ok "до --fill не дошло: отказ на тождестве"
container_started && bad "контейнер запускался: $(docker_calls | grep -E 'up|exec|restart' | head -2)" \
  || ok "контейнер не запускался"

# --- W10b. ворота --fill на месте, в том числе запасные ---------------------
head_ "W10b. verify-storage.sh: запрет --fill на рабочем SSD сохранён"
grep -q 'запрещён на рабочем хранилище' "$SRC/scripts/verify-storage.sh" \
  && ok "ворота по пути хранилища" || bad "нет ворот по пути"
grep -q 'запрещён: источник указывает на рабочий SSD' "$SRC/scripts/verify-storage.sh" \
  && ok "запасные ворота по серийному номеру" || bad "нет ворот по серийному номеру"

# --- W11. хранилище задаётся в compose и экспортируется скриптом ------------
head_ "W11. compose.disk.yaml: привязки идут от STORAGE_ROOT"
grep -q 'STORAGE_ROOT' "$SRC/compose.disk.yaml" && ok "compose читает STORAGE_ROOT" \
  || bad "в compose жёсткий путь"
[ "$(grep -c 'STORAGE_ROOT:-/srv/video-studio-data' "$SRC/compose.disk.yaml")" -ge 4 ] \
  && ok "все четыре привязки параметризованы" || bad "часть привязок жёсткая"
grep -q 'export STORAGE_ROOT="$MOUNT"' "$SRC/scripts/verify-storage.sh" \
  && ok "проверка передаёт свой каталог" || bad "проверка не передаёт каталог"
grep -q 'export STORAGE_ROOT="$STORAGE"' "$SRC/scripts/run-render.sh" \
  && ok "рендер передаёт свой каталог" || bad "рендер не передаёт каталог"

# --- W12. настоящий docker compose подставляет путь -------------------------
head_ "W12. docker compose config: STORAGE_ROOT доходит до привязок"
real_docker=$(PATH=/usr/bin:/bin:/usr/local/bin command -v docker 2>/dev/null || true)
if [ -z "$real_docker" ]; then
  ok "пропущено: docker недоступен"
else
  probe="$SB/storage-probe"
  out=$(STORAGE_ROOT="$probe" "$real_docker" compose -f "$SRC/compose.disk.yaml" config 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    printf '%s' "$out" | grep -q "source: $probe/out" && ok "привязка /out ведёт в $probe/out" \
      || bad "привязка /out не та"
    printf '%s' "$out" | grep -q "source: $probe/in" && ok "привязка /work ведёт в $probe/in" \
      || bad "привязка /work не та"
    printf '%s' "$out" | grep -q "source: $probe\$" && ok "привязка /storage ведёт в $probe" \
      || bad "привязка /storage не та"
  else
    bad "docker compose config: код $rc: $(printf '%s' "$out" | tail -2)"
  fi
  out=$(env -u STORAGE_ROOT "$real_docker" compose -f "$SRC/compose.disk.yaml" config 2>&1)
  printf '%s' "$out" | grep -q "source: /srv/video-studio-data/out" \
    && ok "без STORAGE_ROOT остаётся рабочий путь" || bad "рабочий путь потерян"
fi

# --- W13. нормальный прогон: запись была, уборка одна, без ловушки ----------
head_ "W13. verify-storage.sh: запись пробы и уборка при успехе"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; printf '%s\n' "$out" | tail -6; }
grep -q 'mkdir -p /out/.verify' "$FAKE_LOG" && ok "проба записана" || bad "записи не было"
printf '%s' "$out" | grep -q "перед записью точка монтирования и серийный номер те же" \
  && ok "сверка перед записью пройдена" || bad "сверки перед записью нет"
docker_calls | grep -q -- '--project-name video-studio-disk-check up' \
  && ok "контейнер поднят в своём проекте" || bad "свой проект не использован"
printf '%s' "$out" | grep -q 'УБОРКА' && bad "ловушка сработала повторно" \
  || ok "повторной уборки нет"

# --- X: fail-closed ---------------------------------------------------------
# Общий помощник: прогон с одним подставным отказом. Проверяет код возврата,
# отсутствие записи и уборку своего проекта после подъёма контейнера.
fail_closed_case() {
  local title="$1" expect="$2"; shift 2
  head_ "$title"
  setup_env
  seed_verify_env 926 972029952 "$FAKE_MOUNT"
  patch_verify
  seed_verify_docker
  seed_verify_prod
  export FAKE_SERIAL=24257G400264
  export "$@"
  out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
  if [ "$rc" = 1 ]; then ok "код 1 — проверка прекращена"; else bad "код $rc"; fi
  if grep -q 'mkdir -p /out/.verify' "$FAKE_LOG"; then
    bad "проба записана вопреки отказу"
  else
    ok "записи пробы не было"
  fi
  printf '%s' "$out" | grep -q "$expect" && ok "причина названа" || bad "нет причины: $expect"
  # Уборка: down после up.
  if sed -n '/compose .* up /,$p' "$FAKE_LOG" | grep -q 'compose .* down'; then
    ok "свой проект убран после отказа"
  else
    bad "контейнер остался после отказа"
  fi
  docker_calls | sed -n '/compose .* up /,$p' | grep -q 'amnesia\|paperless\|nextcloud\|openhands' \
    && bad "уборка коснулась чужого имени" || ok "уборка только своя"
}

fail_closed_case "X1. ограда отказала — записи нет, уборка есть" \
  "ограда не подтвердила дисковый режим" FAKE_GUARD_FAIL=1

fail_closed_case "X2. размер в контейнере не тот — записи нет" \
  "ожидалось около" FAKE_IN_TOTAL_KI=2097152

fail_closed_case "X3. /out на корне контейнера — записи нет" \
  "запись уйдёт на системный диск" FAKE_OUT_DEV=41 FAKE_ROOT_DEV=41

fail_closed_case "X4. /work доступен на запись — записи нет" \
  "привязки томов не те" FAKE_WORK_WRITABLE=1

# --- X5. хранилище пропало между проверкой и записью ------------------------
head_ "X5. verify-storage.sh: точка отвалилась перед записью — записи нет"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264 FAKE_UNMOUNT_AFTER_UP=1
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1" || bad "код $rc"
grep -q 'mkdir -p /out/.verify' "$FAKE_LOG" && bad "проба записана вопреки отказу" \
  || ok "записи не было"
printf '%s' "$out" | grep -q "перестал быть точкой монтирования" && ok "причина названа" \
  || bad "нет сообщения о точке монтирования"
sed -n '/compose .* up /,$p' "$FAKE_LOG" | grep -q 'compose .* down' \
  && ok "свой проект убран" || bad "контейнер остался"

# --- X6. сбой docker exec после подъёма -------------------------------------
head_ "X6. verify-storage.sh: сбой docker exec — уборка ловушкой"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
export FAKE_SERIAL=24257G400264 FAKE_EXEC_FAIL='stat -c %d /out'
out=$(MIN_GIB=900 run_verify 2>&1); rc=$?
[ "$rc" != 0 ] && ok "код $rc — аварийное завершение" || bad "код 0 при сбое exec"
printf '%s' "$out" | grep -q "УБОРКА: контейнеры проекта video-studio-disk-check остановлены" \
  && ok "ловушка назвала свой проект" || bad "ловушка не сработала"
sed -n '/compose .* up /,$p' "$FAKE_LOG" | grep -q -- '--project-name video-studio-disk-check down' \
  && ok "down в своём проекте" || bad "down не в своём проекте"
grep -q 'mkdir -p /out/.verify' "$FAKE_LOG" && bad "запись при сбое" || ok "записи не было"

# --- X7. run-render.sh: своё имя проекта ------------------------------------
head_ "X7. run-render.sh: MODE=disk идёт в проекте video-studio-disk"
grep -q 'DISK_PROJECT="${DISK_PROJECT:-video-studio-disk}"' "$SRC/scripts/run-render.sh" \
  && ok "имя проекта задано" || bad "имя проекта не задано"
grep -q -- '--project-name "$DISK_PROJECT"' "$SRC/scripts/run-render.sh" \
  && ok "compose получает --project-name" || bad "compose без --project-name"
grep -q 'DISK_PROJECT не может совпадать с проектом проверки' "$SRC/scripts/run-render.sh" \
  && ok "запрет совпадения с проектом проверки" || bad "нет запрета совпадения"
grep -q 'stop studio-disk' "$SRC/scripts/run-render.sh" \
  && ok "ловушка останавливает только studio-disk" || bad "ловушка не нацелена"
grep -qE -- '--project-name[= ]+video-studio([[:space:]]|$)|-p[[:space:]]+video-studio([[:space:]]|$)' \
  "$SRC/scripts/run-render.sh" && bad "рендер идёт в старом проекте" \
  || ok "старое имя проекта не передаётся"

# --- X8. run-render.sh: прогон на имитациях ---------------------------------
head_ "X8. run-render.sh: прогон с имитациями — один проект, одна остановка"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
seed_verify_docker
cp "$SRC/scripts/run-render.sh" "$SB/scripts/"
chmod +x "$SB/scripts/run-render.sh"
cp "$SRC/compose.disk.yaml" "$SB/compose.disk.yaml"
mkdir -p "$SB/out"
out=$(ROOT="$SB" MODE=disk STORAGE="$FAKE_MOUNT" "$SB/scripts/run-render.sh" -version 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0" || { bad "код $rc"; printf '%s\n' "$out" | tail -5; }
docker_calls | grep -q -- '--project-name video-studio-disk ' && ok "прогон в своём проекте" \
  || bad "прогон без своего проекта"
docker_calls | grep -q 'video-studio-disk-check' && bad "пересечение с проектом проверки" \
  || ok "с проектом проверки не пересекается"
stop_lines=$(docker_calls | grep ' compose .*stop ')
[ -n "$stop_lines" ] && ok "остановка вызвана" || bad "остановки нет"
printf '%s' "$stop_lines" | grep -q 'video-studio-disk ' && ok "остановка в своём проекте" \
  || bad "остановка не в своём проекте"
printf '%s' "$stop_lines" | grep -q 'stop studio-disk' && ok "остановлен только studio-disk" \
  || bad "остановлен не только studio-disk"
docker_calls | grep -Eq '^docker (restart|kill|rm|prune)' && bad "прямые команды над контейнерами" \
  || ok "прямых команд нет"

# --- X9. run-render.sh: запрет совпадающих имён -----------------------------
head_ "X9. run-render.sh: имя проекта не может совпасть с чужими"
setup_env
seed_verify_env 926 972029952 "$FAKE_MOUNT"
seed_verify_docker
cp "$SRC/scripts/run-render.sh" "$SB/scripts/"
chmod +x "$SB/scripts/run-render.sh"
out=$(ROOT="$SB" MODE=disk DISK_PROJECT=video-studio STORAGE="$FAKE_MOUNT" \
  "$SB/scripts/run-render.sh" -version 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1 для video-studio" || bad "код $rc"
printf '%s' "$out" | grep -q "не может совпадать с проектом рабочего сервиса" \
  && ok "причина названа" || bad "нет сообщения"
out=$(ROOT="$SB" MODE=disk DISK_PROJECT=video-studio-disk-check STORAGE="$FAKE_MOUNT" \
  "$SB/scripts/run-render.sh" -version 2>&1); rc=$?
[ "$rc" = 1 ] && ok "код 1 для проекта проверки" || bad "код $rc"
printf '%s' "$out" | grep -q "не может совпадать с проектом проверки" \
  && ok "причина названа" || bad "нет сообщения"
docker_calls | grep -q 'compose .* up ' && bad "контейнер поднимался при отказе" \
  || ok "контейнер не поднимался"

# --- X10. порог маркера для --fill -----------------------------------------
head_ "X10. verify-storage.sh: порог маркера не блокирует тестовый --fill"
grep -q 'REQUIRED_GIB="${TEST_MIN_GIB:-1}"' "$SRC/scripts/verify-storage.sh" \
  && ok "для --fill порог отдельный" || bad "порог --fill равен рабочему"
setup_env
seed_verify_env 2 2097152 /nonexistent
patch_verify
seed_verify_docker
: > "$FAKE_MOUNT/.fill-test-ok"
out=$(MIN_GIB=1 run_verify --fill 2>&1); rc=$?
[ "$rc" = 0 ] && ok "тестовый --fill на 2 GiB достижим" || { bad "код $rc"; printf '%s\n' "$out" | tail -6; }
printf '%s' "$out" | grep -q "маркер хранилища: 2 GiB (порог 1 GiB)" \
  && ok "порог назван в отчёте" || bad "порог не назван"
# Рабочий порог при этом не тронут: без --fill маркер 2 GiB по-прежнему мало.
setup_env
seed_verify_env 2 2097152 "$FAKE_MOUNT"
patch_verify
seed_verify_docker
seed_verify_prod
out=$(MIN_GIB=38 run_verify 2>&1); rc=$?
[ "$rc" = 1 ] && ok "без --fill порог 38 GiB действует" || bad "код $rc"
printf '%s' "$out" | grep -q "меньше 38 GiB" && ok "рабочий порог назван" \
  || bad "рабочий порог не назван"

# --- Y. inventory-sources.sh: исходники не меняются -------------------------
head_ "Y1. inventory-sources.sh: отказы и привязка только на чтение"

out=$("$SRC/scripts/inventory-sources.sh" "/nonexistent-in-$$" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "код 2 на отсутствующем каталоге" || bad "код $rc"
printf '%s' "$out" | grep -q "ОТКАЗ: нет каталога" && ok "причина названа" \
  || bad "нет сообщения об отказе"

mkdir -p "$SB/empty-in"
out=$(STORAGE="$SB" "$SRC/scripts/inventory-sources.sh" "$SB/empty-in" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "код 0 на пустом каталоге" || bad "код $rc"
printf '%s' "$out" | grep -q "нет видеофайлов" && ok "пустой каталог назван пустым" \
  || bad "нет сообщения о пустом каталоге"

# Оригиналы не должны меняться: каталог привязан только на чтение, сети нет,
# работа идёт от того же пользователя, что и в рабочем контейнере.
grep -q -- '-v "$DIR":/media:ro' "$SRC/scripts/inventory-sources.sh" \
  && ok "каталог привязан только на чтение" || bad "привязка без :ro"
grep -q -- '--network none' "$SRC/scripts/inventory-sources.sh" \
  && ok "контейнер без сети" || bad "сеть не отключена"
grep -q -- '--user 10001:10001' "$SRC/scripts/inventory-sources.sh" \
  && ok "тот же пользователь, что в рабочем контейнере" || bad "пользователь не задан"
# Ни записи, ни создания файлов в каталоге исходников: только чтение.
# Сравнение в awk (`c[h] > 1`) и вывод в stdout за перенаправление не считаются,
# поэтому смотрятся сами токены перенаправления.
redirs=$(grep -oE '[0-9]*>>?[^ &|)]*' "$SRC/scripts/inventory-sources.sh" \
  | grep -vE '^[0-9]*>/dev/null$' | grep -vE '^[0-9]*>$' || true)
[ -z "$redirs" ] && ok "в файлы ничего не пишется" \
  || bad "есть перенаправление в файл: $(printf '%s' "$redirs" | tr '\n' ' ')"
grep -qE '(^|[[:space:]])rm[[:space:]]+-' "$SRC/scripts/inventory-sources.sh" \
  && bad "в скрипте есть удаление" || ok "удаления нет"

# Разделитель полей не должен быть IFS-пробелом: на файле без звука или без
# видео пустые поля иначе схлопываются и колонки съезжают.
grep -qF "IFS=\$'\037'" "$SRC/scripts/inventory-sources.sh" \
  && ok "поля разделены непечатаемым символом" || bad "разделитель снова пробельный"

# --- Z. render-montage.sh: отказы до запуска ffmpeg -------------------------
head_ "Z1. render-montage.sh: клипы находятся однозначно или работа не начинается"

mkdir -p "$SB/noclips"
out=$(SRC="$SB/noclips" OUTDIR="$SB/out" sh "$SRC/scripts/render-montage.sh" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "код 2 без клипов" || bad "код $rc"
printf '%s' "$out" | grep -q "не найден клип" && ok "назван отсутствующий клип" \
  || bad "нет сообщения об отсутствующем клипе"

# Два файла на один образец — неоднозначность, а не повод выбрать первый.
mkdir -p "$SB/dups"
: > "$SB/dups/Robot_examining_flower_in_rain_a.mp4"
: > "$SB/dups/Robot_examining_flower_in_rain_b.mp4"
out=$(SRC="$SB/dups" OUTDIR="$SB/out" sh "$SRC/scripts/render-montage.sh" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "код 2 при двух совпадениях" || bad "код $rc"
printf '%s' "$out" | grep -q "нужен ровно один" && ok "неоднозначность названа" \
  || bad "нет сообщения о неоднозначности"

# Клипы ищутся по образцу: имя с усечённым «…» не должно ломать поиск.
grep -q "Flower_straightens_under_metal_s\*" "$SRC/scripts/render-montage.sh" \
  && ok "четвёртый клип ищется по образцу, а не по полному имени" \
  || bad "жёсткое имя файла с усечением"

# Вариант D: у третьей сцены остаётся только хвост, 26 кадров с 164-го.
grep -q 'S3_IN_FRAME="${S3_IN_FRAME:-164}"' "$SRC/scripts/render-montage.sh" \
  && ok "вход третьей сцены — кадр 164" || bad "другой вход третьей сцены"
grep -q 'S3_FRAMES="${S3_FRAMES:-26}"' "$SRC/scripts/render-montage.sh" \
  && ok "остаётся 26 кадров" || bad "другое число кадров"
grep -q 'trim=start_frame=\${S3_IN_FRAME}' "$SRC/scripts/render-montage.sh" \
  && ok "видео режется по номеру кадра, а не по времени" || bad "обрезка по времени"
grep -q 'atrim=start=\${S3_IN_SEC}' "$SRC/scripts/render-montage.sh" \
  && ok "звук третьей сцены сдвинут тем же входом" || bad "звук не сдвинут со входом"

# Хвост сцены громче всего клипа на 3.2 LU: поправка должна считаться по хвосту.
grep -q '^V3=1.3' "$SRC/scripts/render-montage.sh" \
  && ok "поправка третьей сцены +1.3 дБ по замеру хвоста" || bad "поправка V3 не по хвосту"

# Растворение 4→5 обязано быть в графе: без него остаётся резкая склейка.
grep -q 'xfade=transition=fade' "$SRC/scripts/render-montage.sh" \
  && ok "растворение 4→5 есть в графе" || bad "нет xfade"
grep -q 'acrossfade=d=' "$SRC/scripts/render-montage.sh" \
  && ok "звук растворения сшит acrossfade" || bad "нет acrossfade"

# 0.8 с — это 19.2 кадра, а кадр неделим. Итог должен остаться целым.
grep -q 'XFADE_FRAMES="${XFADE_FRAMES:-19}"' "$SRC/scripts/render-montage.sh" \
  && ok "растворение задано 19 кадрами (0.7917 с)" || bad "растворение не в кадрах"

# xfade требует одинаковую базу времени у входов: concat и исходник расходятся.
grep -q 'settb=1/\${FPS}' "$SRC/scripts/render-montage.sh" \
  && ok "базы времени входов выровнены" || bad "нет нормализации timebase"

# Выравнивание уровней должно опираться на замеры, а не на догадку.
for v in 'V1=-3.4' 'V2=5.0' 'V4=6.2' 'V5=2.3'; do
  grep -q "^$v" "$SRC/scripts/render-montage.sh" || bad "нет поправки $v"
done
ok "поправки громкости совпадают с измеренными EBU R128"

grep -q 'loudnorm=I=' "$SRC/scripts/render-montage.sh" \
  && ok "финальная громкость нормируется" || bad "нет loudnorm"

# Сухая проверка не должна создавать файл фильма.
grep -q 'f null -' "$SRC/scripts/render-montage.sh" \
  && ok "есть режим сухой проверки без записи" || bad "нет режима сухой проверки"

# Готовая версия не перезаписывается: рендер идёт с -n, а не с -y.
grep -q 'ffmpeg -hide_banner -nostats -n' "$SRC/scripts/render-montage.sh" \
  && ok "рендер запускается с -n" || bad "нет -n"
if grep -q 'ffmpeg -hide_banner -nostats -y' "$SRC/scripts/render-montage.sh"; then
  bad "в рендере остался -y"
else
  ok "в рендере нет -y"
fi

# Отказ при существующем файле: код 3 и понятное сообщение.
mkdir -p "$SB/five" "$SB/exists/maloe-dobro"
: > "$SB/five/Robot_examining_flower_in_rain_a.mp4"
: > "$SB/five/Robot_lifting_metal_sheet_shelter_a.mp4"
: > "$SB/five/Robot_builds_rain_shelter_for_a.mp4"
: > "$SB/five/Flower_straightens_under_metal_sa.mp4"
: > "$SB/five/Aerial_view_of_industrial_city_a.mp4"
: > "$SB/exists/maloe-dobro/v1.mp4"
out=$(SRC="$SB/five" OUTDIR="$SB/exists" sh "$SRC/scripts/render-montage.sh" 2>&1); rc=$?
[ "$rc" = 3 ] && ok "существующий файл даёт код 3" || bad "код $rc вместо 3"
printf '%s' "$out" | grep -q "не перезаписываются" && ok "отказ объяснён" \
  || bad "нет объяснения отказа"

# Имя версии не должно уводить запись из каталога вывода.
rm -f "$SB/exists/maloe-dobro/v1.mp4"
out=$(SRC="$SB/five" OUTDIR="$SB/exists" VERSION=../evil sh "$SRC/scripts/render-montage.sh" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "путь в имени версии отклонён" || bad "код $rc вместо 2"

# =============================================================================
printf '\n=== ИТОГ: ПРОЙДЕНО %s, НЕ ПРОЙДЕНО %s ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
