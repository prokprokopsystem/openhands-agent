#!/usr/bin/env bash
# Подготовка внешнего SSD видеостудии: GPT + ext4, монтирование по UUID.
#
#   ./host/setup-ssd-storage.sh                 # план, ничего не меняет
#   sudo ./host/setup-ssd-storage.sh --apply --confirm-serial 24257G400264
#
# Идентичность диска задана константами и не переопределяется ни окружением, ни
# аргументами: иначе под привилегиями можно было бы подменить диск, его серийный
# номер или точку монтирования и обойти все проверки.
#
# Прогон один. План и исполнение идут через одну функцию stage(): в режиме
# плана она только печатает, в режиме --apply печатает и выполняет. Второго
# прохода по тем же командам нет, поэтому повторного mkfs быть не может.
set -euEo pipefail

readonly DEV="/dev/disk/by-id/usb-SanDisk_Extreme_55AE_323432353747343030323634-0:0"
readonly EXPECT_SERIAL="24257G400264"
readonly EXPECT_MODEL="Extreme 55AE"
readonly EXPECT_TRAN="usb"
readonly MIN_SIZE_BYTES=966367641600          # 900 GiB
readonly FORBIDDEN_SERIALS="4F0029407 181066800481"
readonly FORBIDDEN_NAMES="sda"

readonly MOUNT="/srv/video-studio-data"
readonly LABEL="VIDEO_STUDIO"
readonly INODE_BYTES=65536
readonly OPERATOR="igor"
readonly CONTAINER_UID=10001
readonly CONTAINER_GID=10001

readonly FSTAB="/etc/fstab"
readonly FSTAB_OPTS="rw,nosuid,nodev,noexec,noatime,nofail,errors=remount-ro,x-systemd.device-timeout=30s"

APPLY=0
CONFIRM_SERIAL=""
UUID=""
BACKUP_FSTAB=""
FSTAB_MODIFIED=0
MOUNTED_BY_US=0
NEED_PARTITION=1
FS_READY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --confirm-serial)
      [ $# -ge 2 ] || { printf 'ОТКАЗ: --confirm-serial требует значение\n' >&2; exit 2; }
      CONFIRM_SERIAL="$2"; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) printf 'ОТКАЗ: неизвестный аргумент %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

# Модуль сверки размера лежит либо в корне проекта (раскладка репозитория),
# либо в каталоге образа (раскладка на сервере, где build context — отдельный
# каталог). Путь разрешается до первого шага: иначе отсутствие модуля
# всплывало бы в самом конце, после разметки, mkfs и mount.
SIZE_CHECK_LIB=""
for c in "$(dirname "$0")/../size-check.sh" "$(dirname "$0")/../image/ffmpeg/size-check.sh"; do
  if [ -r "$c" ]; then SIZE_CHECK_LIB="$c"; break; fi
done
[ -n "$SIZE_CHECK_LIB" ] || die "не найден size-check.sh ни в корне проекта, ни в image/ffmpeg"

# Права проверяются до любого шага, включая чтение устройства: без root
# режим --apply не имеет смысла и не должен доходить до разрушительных команд.
if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply --confirm-serial $EXPECT_SERIAL"
  [ "$CONFIRM_SERIAL" = "$EXPECT_SERIAL" ] || \
    die "подтверждение не совпало: ожидалось --confirm-serial $EXPECT_SERIAL"
fi

# Раздел должен читаться. blkid на отсутствующий путь отвечает кодом 2 без
# текста в stderr, поэтому «сигнатуры нет» и «доступа нет» по нему неразличимы.
# Чтение первых 512 байт отвечает на этот вопрос напрямую.
assert_part_readable() {
  local part="$1" err_file rc msg
  err_file=$(mktemp) || die "mktemp не удался"
  rc=0
  dd if="$part" of=/dev/null bs=512 count=1 status=none 2>"$err_file" || rc=$?
  msg=$(tr '\n' ' ' < "$err_file" | tr -s ' ' | sed 's/^ //; s/ $//')
  rm -f "$err_file"
  [ "$rc" = 0 ] || die "раздел $part не читается (dd, код $rc): ${msg:-без сообщения}"
  [ -z "$msg" ] || die "чтение $part сообщило об ошибке: $msg"
}

# Подписи файловых систем в разделе: тип из blkid -p (чтение с устройства, а не
# из кэша udev) плюс типы из wipefs -n. Столбцы wipefs заданы явно: вывод по
# умолчанию начинается с имени устройства, и разбор по положению давал пустоту.
# Пустой результат означает, что стирать нечего; ошибка любой из утилит — отказ,
# а не «чисто».
probe_signatures() {
  local part="$1" out err_file rc blkid_types wipefs_types msg
  assert_part_readable "$part"
  out=$(mktemp) || die "mktemp не удался"
  err_file=$(mktemp) || { rm -f "$out"; die "mktemp не удался"; }

  # blkid: 0 — тип опознан либо у найденного объекта нет токена TYPE (так
  # выглядит таблица разделов), 2 — ничего не опознано. Остальные коды —
  # ошибка. Текст в stderr — тоже ошибка, даже при коде 2.
  rc=0
  blkid -p -o value -s TYPE "$part" >"$out" 2>"$err_file" || rc=$?
  blkid_types=$(tr '\n' ' ' < "$out" | tr -s ' ' | sed 's/^ //; s/ $//')
  msg=$(tr '\n' ' ' < "$err_file" | tr -s ' ' | sed 's/^ //; s/ $//')
  case "$rc" in
    0|2)
      if [ -n "$msg" ]; then
        rm -f "$out" "$err_file"
        die "blkid -p не смог прочитать $part (код $rc): $msg"
      fi
      ;;
    *)
      rm -f "$out" "$err_file"
      die "blkid -p завершился с кодом $rc${msg:+: $msg}
Считать раздел чистым по такому ответу нельзя."
      ;;
  esac

  # wipefs: столбцы перечислены явно, формат по умолчанию не разбирается.
  # Ненулевой код — ошибка чтения, а не отсутствие подписей.
  rc=0
  wipefs --no-act --noheadings --output TYPE "$part" >"$out" 2>"$err_file" || rc=$?
  wipefs_types=$(tr '\n' ' ' < "$out" | tr -s ' ' | sed 's/^ //; s/ $//')
  msg=$(tr '\n' ' ' < "$err_file" | tr -s ' ' | sed 's/^ //; s/ $//')
  rm -f "$out" "$err_file"
  [ "$rc" = 0 ] || die "wipefs -n завершился с кодом $rc${msg:+: $msg}
Считать раздел чистым по такому ответу нельзя."

  { printf '%s\n' $blkid_types; printf '%s\n' $wipefs_types; } \
    | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Проверка адресации: раздел обязан быть первым разделом именно того узла, на
# который сейчас ведёт зашитая by-id ссылка. Это защита от wipefs по чужому
# устройству, если диск вынули и вставили другой.
assert_part_target() {
  local part="$1" cur_real base n
  [ -e "$part" ] || die "раздел $part не найден"
  cur_real=$(readlink -f "$DEV" 2>/dev/null || true)
  [ -n "$cur_real" ] || die "$DEV больше никуда не ведёт — устройство отключено"
  [ "$cur_real" = "$real" ] || \
    die "by-id ссылка теперь ведёт на $cur_real вместо $real — устройство переподключено"
  [ "$(lsblk -dno SERIAL "$DEV" 2>/dev/null || true)" = "$EXPECT_SERIAL" ] || \
    die "серийный номер изменился с момента проверки — не тот диск"
  [ "$(lsblk -dno MODEL "$DEV" 2>/dev/null | sed 's/[[:space:]]*$//')" = "$EXPECT_MODEL" ] || \
    die "модель изменилась с момента проверки — не тот диск"
  base=$(basename "$real")
  for n in $FORBIDDEN_NAMES; do
    [ "$base" != "$n" ] || die "$real — запрещённое имя устройства ($n)"
  done
  [ "$(readlink -f "$part" 2>/dev/null || true)" = "${real}1" ] || \
    die "$part не принадлежит $real — работа с этим разделом запрещена"
}

# Раздел не должен быть смонтирован, занят как swap, служить основой для dm и
# держаться открытым каким-либо процессом.
assert_part_free() {
  local part="$1" sysdir holders pids
  findmnt -S "$part" -n -o TARGET 2>/dev/null | grep -q . && \
    die "$part смонтирован: $(findmnt -S "$part" -n -o TARGET | tr '\n' ' ')"
  lsblk -pno NAME,MOUNTPOINTS "$part" 2>/dev/null | awk '$2 != "" {print $1}' | grep -q . && \
    die "раздел смонтирован в дереве: $(lsblk -pno NAME,MOUNTPOINTS "$part" 2>/dev/null | awk '$2 != "" {print $1}' | tr '\n' ' ')"
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$part" && die "$part используется как swap"

  # Имя в sysfs — узел ядра (sdc1), а не by-id ссылка.
  sysdir="/sys/block/$(basename "$real")/$(basename "$(readlink -f "$part")")"
  if [ -d "$sysdir/holders" ]; then
    holders=$(ls -A "$sysdir/holders" 2>/dev/null || true)
    [ -z "$holders" ] || die "раздел используется как основа: $(printf '%s' "$holders" | tr '\n' ' ')"
  fi

  # fuser без -m перечисляет процессы с открытым устройством; на несмонтированном
  # разделе это единственная доступная проверка. Оба инструмента присутствуют
  # на mini-server; если исчезнут оба, работа не начинается.
  if command -v fuser >/dev/null 2>&1; then
    if fuser -s "$part" 2>/dev/null; then
      pids=$(fuser "$part" 2>&1 | tr -s ' ')
      die "раздел открыт процессом:$pids"
    fi
  elif command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -t "$part" 2>/dev/null | tr '\n' ' ')
    [ -z "$pids" ] || die "раздел открыт процессом: $pids"
  else
    die "нет ни fuser, ни lsof — проверить, что раздел свободен, нечем"
  fi
}

# Единственная точка исполнения. В плане печатает, в --apply печатает и
# выполняет. Именно поэтому план не может ничего изменить: он и есть этот же
# проход, только без вызова функции.
stage() {
  local desc="$1" fn="$2"
  if [ "$APPLY" = "1" ]; then
    printf '+ %s\n' "$desc"
    "$fn"
  else
    printf '  %s\n' "$desc"
  fi
}

rollback() {
  rc=$?
  # Срабатывает на любом выходе: и на необработанной ошибке (set -e), и на
  # явном die. Ошибка в условии вида «cmd || die» в ERR не попадает, поэтому
  # EXIT надёжнее, чем ERR: откат нужен в обоих случаях.
  [ "$rc" = "0" ] && exit 0
  [ "$APPLY" = "1" ] || exit "$rc"
  # Ошибка внутри самого отката не должна вызывать откат повторно.
  [ "${ROLLING_BACK:-0}" = "1" ] && exit "$rc"
  ROLLING_BACK=1
  set +e
  printf '\n=== Откат после ошибки (код %s) ===\n' "$rc" >&2

  if [ "$FSTAB_MODIFIED" = "1" ] && [ -n "$BACKUP_FSTAB" ] && [ -f "$BACKUP_FSTAB" ]; then
    if cp -a "$BACKUP_FSTAB" "$FSTAB"; then
      systemctl daemon-reload 2>/dev/null || true
      printf 'fstab восстановлен из %s\n' "$BACKUP_FSTAB" >&2
    else
      printf 'ВНИМАНИЕ: не удалось восстановить fstab. Копия: %s\n' "$BACKUP_FSTAB" >&2
    fi
  fi

  if [ "$MOUNTED_BY_US" = "1" ] && findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
    umount "$MOUNT" 2>/dev/null && printf 'размонтировано %s\n' "$MOUNT" >&2 \
      || printf 'ВНИМАНИЕ: %s остался смонтирован\n' "$MOUNT" >&2
  fi

  # Раздел и файловая система НЕ удаляются: они уже созданы, а автоматическое
  # стирание опаснее, чем оставить созданное и сказать об этом. Удалять живой
  # образ или форматировать заново без человека нельзя.
  printf '\nФактическое состояние:\n' >&2
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DEV" >&2 || true
  printf 'Разметка и файловая система не удаляются автоматически.\n' >&2
  printf 'Повторный запуск пройдёт только после ручного разбора.\n' >&2
  exit "$rc"
}
trap rollback EXIT

step "1. Идентичность устройства"

[ -L "$DEV" ] || die "$DEV не найден или не ссылка by-id — SSD не подключён либо переименован"
real=$(readlink -f "$DEV")
[ -b "$real" ] || die "$real не блочное устройство"

serial=$(lsblk -dno SERIAL "$DEV")
model=$(lsblk -dno MODEL "$DEV" | sed 's/[[:space:]]*$//')
tran=$(lsblk -dno TRAN "$DEV")
size=$(lsblk -bdno SIZE "$DEV")
name=$(basename "$real")

[ "$serial" = "$EXPECT_SERIAL" ] || die "серийный '$serial' не совпадает с '$EXPECT_SERIAL'"
[ "$model" = "$EXPECT_MODEL" ] || die "модель '$model' не совпадает с '$EXPECT_MODEL'"
[ "$tran" = "$EXPECT_TRAN" ] || die "шина '$tran', ожидалась '$EXPECT_TRAN'"
[ "$size" -ge "$MIN_SIZE_BYTES" ] || die "объём $size байт меньше $MIN_SIZE_BYTES"
for n in $FORBIDDEN_NAMES; do
  [ "$name" != "$n" ] || die "$real — запрещённое имя устройства ($n)"
done
for s in $FORBIDDEN_SERIALS; do
  [ "$serial" != "$s" ] || die "серийный $s в списке запрещённых"
done

say "ПРОЙДЕНО: $DEV -> $real"
say "  модель $model, серийный $serial, шина $tran, $(lsblk -dno SIZE "$DEV")"

# Повторный запуск после успешной настройки — не ошибка и не повод что-то
# делать. Проверяется до отказа по монтированиям: рабочее хранилище всегда
# смонтировано, и без этой ветки повторный запуск выглядел бы поломкой.
if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  mounted_src=$(findmnt -no SOURCE "$MOUNT")
  if [ "$(readlink -f "$mounted_src")" = "$(readlink -f "${DEV}-part1")" ] && \
     [ -r "$MOUNT/.storage-size-gib" ]; then
    say ""
    say "УЖЕ НАСТРОЕНО: $MOUNT смонтирован с $mounted_src, маркер $(cat "$MOUNT/.storage-size-gib") GiB"
    say "Изменений не требуется."
    exit 0
  fi
fi

step "2. Монтирования и swap"

findmnt -S "$real" -n -o TARGET 2>/dev/null | grep -q . && \
  die "с $real уже смонтировано: $(findmnt -S "$real" -n -o TARGET | tr '\n' ' ')"
lsblk -pno NAME,MOUNTPOINTS "$DEV" | awk '$2 != "" {print $1}' | grep -q . && \
  die "смонтированы разделы: $(lsblk -pno NAME,MOUNTPOINTS "$DEV" | awk '$2 != "" {print $1}' | tr '\n' ' ')"
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$real"; then
  die "$real используется как swap"
fi
say "ПРОЙДЕНО: монтирований и swap нет"

step "3. Разметка и файловые системы"

pttype=$(lsblk -dno PTTYPE "$DEV" 2>/dev/null || true)
labels=$(lsblk -no LABEL "$DEV" 2>/dev/null | grep -v '^$' | sort -u | tr '\n' ' ' || true)
fstypes=$(lsblk -no FSTYPE "$DEV" 2>/dev/null | grep -v '^$' | sort -u | tr '\n' ' ' || true)
part_count=$(lsblk -no NAME "$DEV" 2>/dev/null | tail -n +2 | grep -c . || true)
part_type=$(lsblk -no PARTTYPE "${DEV}-part1" 2>/dev/null | tr -d ' ' || true)
part_label=$(lsblk -no PARTLABEL "${DEV}-part1" 2>/dev/null | tr -d ' ' || true)
# lsblk дополняет числа пробелами до ширины столбца, поэтому пробелы снимаются
# до разбора: иначе " 2048" не пройдёт проверку «только цифры».
part_start=$(lsblk -bno START "${DEV}-part1" 2>/dev/null | tr -d '[:space:]' || true)
part_bytes=$(lsblk -bno SIZE "${DEV}-part1" 2>/dev/null | tr -d '[:space:]' || true)
disk_bytes=$(lsblk -bdno SIZE "$DEV" 2>/dev/null | tr -d '[:space:]' || true)
case "$part_count" in ''|*[!0-9]*) part_count=0 ;; esac
case "$part_start" in ''|*[!0-9]*) part_start=0 ;; esac
case "$part_bytes" in ''|*[!0-9]*) part_bytes=0 ;; esac
case "$disk_bytes" in ''|*[!0-9]*) disk_bytes=0 ;; esac

say "  таблица разделов: ${pttype:-нет}"
say "  разделов:         $part_count"
say "  файловые системы: ${fstypes:-нет}"
say "  метки:            ${labels:-нет}"

# Признак нашего хранилища — метка раздела или метка ФС. Пока их нет, диск
# считается чужим и размечается заново (владелец разрешил уничтожить данные
# только на этом SSD). Как только признак появился, расхождение с ожидаемой
# геометрией — повод остановиться, а не переделать.
our_trace=0
[ "$part_label" = "$LABEL" ] && our_trace=1
case " $labels " in *" $LABEL "*) our_trace=1 ;; esac

layout_ok=0
if [ "$pttype" = "gpt" ] && [ "$part_count" = "1" ] && [ "$part_start" = "2048" ] && \
   { [ "$part_type" = "0fc63daf-8483-4772-8e79-3d69d8477de4" ] || [ "$part_type" = "8300" ]; }; then
  if [ "$part_bytes" -gt 0 ] && [ "$disk_bytes" -ge "$part_bytes" ]; then
    tail_gap=$(( disk_bytes - part_bytes ))
    [ "$tail_gap" -le 4194304 ] && layout_ok=1
  fi
fi

if [ "$our_trace" = "1" ]; then
  if [ "$layout_ok" = "1" ]; then
    NEED_PARTITION=0
    say "ПРОЙДЕНО: разметка создана предыдущей попыткой и совпадает с ожидаемой"
    say "  GPT, один раздел, тип 8300, метка $LABEL, начало 2048, размер $part_bytes байт"
    say "  повторные sgdisk --zap-all и --new не выполняются"
  else
    die "разметка не совпадает с ожидаемой, а следы хранилища $LABEL уже есть —
автоматически не исправляю.
Ожидалось: GPT, ровно один раздел, тип 8300, метка $LABEL, начало 2048,
размер до конца диска.
Фактически: таблица '${pttype:-нет}', разделов $part_count, тип '${part_type:-нет}',
метка раздела '${part_label:-нет}', начало '${part_start:-нет}', размер '${part_bytes:-нет}'.
Решение принимает человек: разберитесь в состоянии диска вручную."
  fi
else
  NEED_PARTITION=1
  say "  разметки нашего хранилища нет: будет создана заново"
  if [ -n "$pttype" ]; then
    say "  ВНИМАНИЕ: разметка '$pttype' будет уничтожена при --apply"
  fi
fi

is_ext4=0
case " $fstypes " in *" ext4 "*) is_ext4=1 ;; esac
our_fs_label=0
case " $labels " in *" $LABEL "*) our_fs_label=1 ;; esac

if [ "$our_fs_label" = "1" ]; then
  if [ "$layout_ok" = "1" ] && [ "$is_ext4" = "1" ]; then
    UUID=$(blkid -p -o value -s UUID "${DEV}-part1" 2>/dev/null || true)
    [ -n "$UUID" ] || die "ext4 с меткой $LABEL есть, но UUID раздела не читается — разберитесь вручную"
    FS_READY=1
    say "ПРОЙДЕНО: раздел уже содержит ext4 с меткой $LABEL, UUID $UUID"
    say "  wipefs и mkfs.ext4 не выполняются: форматирование не повторяется"
  else
    die "на устройстве уже есть метка $LABEL, но это не ext4 в ожидаемой разметке —
автоматическое переформатирование не выполняется.
Если пересоздание действительно нужно:
  1. Убедитесь, что данные не нужны.
  2. Снимите подписи вручную: sudo wipefs -a ${DEV}-part1
  3. Запустите этот скрипт заново."
  fi
fi

step "4. Точка монтирования"

if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  die "$MOUNT уже смонтирован с $(findmnt -no SOURCE "$MOUNT") — это не наше хранилище, разберитесь вручную"
fi
if [ -d "$MOUNT" ] && [ -n "$(ls -A "$MOUNT" 2>/dev/null || true)" ]; then
  die "каталог $MOUNT не пуст, а монтирования нет: там данные на системном разделе.
Разберитесь вручную, автоматически такое не удаляется."
fi
say "ПРОЙДЕНО: $MOUNT свободен"

# --- Шаги, которые меняют систему ---

do_zap() {
  sgdisk --zap-all "$DEV"
  partprobe "$real" || true
  udevadm settle
}

do_partition() {
  sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:"$LABEL" "$DEV"
  partprobe "$real" || true
  udevadm settle
  [ -b "${DEV}-part1" ] || die "раздел ${DEV}-part1 не появился после разметки"
}

do_wipe() {
  local part="${DEV}-part1" found
  # Адресация и занятость перепроверяются непосредственно перед стиранием:
  # между началом работы и этим шагом диск могли вынуть, а раздел — открыть.
  assert_part_target "$part"
  assert_part_free "$part"

  # Причина приглашения mkfs — подписи прежней ФС внутри раздела: sgdisk
  # переписывает только таблицу разделов. Если подписей нет, wipefs не нужен.
  found=$(probe_signatures "$part")
  if [ -z "$found" ]; then
    say "  подписей файловых систем в разделе нет, wipefs не требуется"
    return 0
  fi
  say "  найдено: $found — стираю подписи только в разделе $part"
  wipefs -a "$part" || die "wipefs не удался — дальше не иду"
  udevadm settle --timeout=10 >/dev/null 2>&1 || true

  found=$(probe_signatures "$part")
  [ -z "$found" ] || die "после wipefs в разделе остались подписи: $found
Дальше не иду: mkfs.ext4 снова спросил бы подтверждение, а --apply обязан быть
неинтерактивным. Разберитесь вручную."
}

do_mkfs() {
  local part="${DEV}-part1"
  assert_part_target "$part"
  assert_part_free "$part"
  # stdin от /dev/null: приглашение mkfs.ext4 при неинтерактивном запуске
  # превращается в немедленный отказ с кодом 1, а не в ожидание человека.
  # -F не используется: он отключает защиту, которую мы как раз проверяем.
  mkfs.ext4 -m 0 -i "$INODE_BYTES" -L "$LABEL" "$part" < /dev/null || \
    die "mkfs.ext4 отказал. Повторного форматирования не было; причина — в выводе выше."
  UUID=$(blkid -s UUID -o value "${DEV}-part1")
  [ -n "$UUID" ] || die "не удалось получить UUID раздела"
  # Ссылку /dev/disk/by-uuid создаёт udev. Без ожидания findmnt --verify на
  # следующем шаге не увидит источник и откажет на ровном месте.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "/dev/disk/by-uuid/$UUID" ] && break
    udevadm settle --timeout=2 >/dev/null 2>&1 || true
    sleep 0.2
  done
}

do_fstab() {
  [ -n "$UUID" ] || die "UUID не получен, строку fstab писать нечем"
  [ -f "$FSTAB" ] || die "$FSTAB не найден"

  # Уже есть наша строка — не добавляем вторую.
  if grep -qE "^UUID=$UUID[[:space:]]+$MOUNT[[:space:]]" "$FSTAB"; then
    say "  строка для $MOUNT уже есть в fstab, не дублирую"
    return 0
  fi
  grep -qE "[[:space:]]$MOUNT[[:space:]]" "$FSTAB" && \
    die "в fstab уже есть другая запись для $MOUNT — разберитесь вручную"

  BACKUP_FSTAB="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$FSTAB" "$BACKUP_FSTAB" || die "не удалось создать резервную копию fstab"
  say "  резервная копия: $BACKUP_FSTAB"

  # Новая редакция собирается отдельно и проверяется до записи. Так сбой
  # findmnt --verify не оставляет полузаписанный fstab.
  tmp=$(mktemp) || die "mktemp не удался"
  cat "$FSTAB" > "$tmp" || die "не удалось прочитать fstab"
  printf 'UUID=%s %s ext4 %s 0 0\n' "$UUID" "$MOUNT" "$FSTAB_OPTS" >> "$tmp" || \
    die "не удалось дописать строку в копию fstab"

  # findmnt --verify проверяет и разбор, и достижимость источника с целью.
  # Раздел создан секунду назад, поэтому источник может быть ещё не виден в
  # /dev/disk/by-uuid. Ошибки, называющие только нашу строку, ожидаемы; любая
  # другая ошибка или ошибка разбора — отказ.
  verify_out=$(mktemp) || die "mktemp не удался"
  # LC_ALL=C: разбор вывода ниже опирается на английские слова.
  if ! LC_ALL=C findmnt --verify --tab-file="$tmp" > "$verify_out" 2>&1; then
    unexpected=$(grep -E '\[E\]' "$verify_out" | grep -vF "UUID=$UUID" | grep -vF "$MOUNT" || true)
    grep -qE '(^|[^0-9])0 parse errors' "$verify_out" || unexpected="$unexpected разбор"
    if [ -n "$unexpected" ]; then
      say "  findmnt --verify нашёл проблему в новой редакции:"
      sed 's/^/    /' "$verify_out"
      rm -f "$verify_out"
      die "fstab не изменён: новая редакция не прошла проверку"
    fi
    say "  findmnt --verify: источник $UUID ещё не виден в by-uuid, ждём после монтирования"
  fi
  rm -f "$verify_out"
  # Контроль, что остальные записи не потерялись при сборке.
  before=$(grep -cvE '^[[:space:]]*(#|$)' "$FSTAB" || true)
  after=$(grep -cvE '^[[:space:]]*(#|$)' "$tmp" || true)
  before=${before:-0}
  after=${after:-0}
  [ "$after" -eq $(( before + 1 )) ] || \
    die "в новой редакции $after записей вместо $(( before + 1 )) — fstab не изменён"

  # Запись перезаписью содержимого, без временного файла рядом с fstab:
  # сохраняется inode, а при сбое остаётся резервная копия.
  if ! cat "$tmp" > "$FSTAB"; then
    cp -a "$BACKUP_FSTAB" "$FSTAB" || true
    die "не удалось записать fstab, восстановлена резервная копия"
  fi
  FSTAB_MODIFIED=1

  # Проверка после записи: строка на месте и файл не пуст.
  if ! grep -qE "^UUID=$UUID[[:space:]]+$MOUNT[[:space:]]" "$FSTAB"; then
    cp -a "$BACKUP_FSTAB" "$FSTAB" || true
    FSTAB_MODIFIED=0
    die "запись в fstab не подтвердилась, восстановлена резервная копия"
  fi
  say "  ИЗМЕНЕНО: $FSTAB"
  systemctl daemon-reload
  rm -f "$tmp"
}

do_mountpoint() {
  # mount не создаёт точку монтирования, а findmnt --verify считает
  # несуществующую цель ошибкой. Поэтому каталог создаётся до записи fstab:
  # иначе проверка fstab отказывала бы всегда.
  [ -d "$MOUNT" ] || install -d -m 0755 "$MOUNT"
}

do_mount() {
  mount "$MOUNT" || die "mount $MOUNT не удался"
  MOUNTED_BY_US=1
  src=$(findmnt -no SOURCE "$MOUNT")
  [ "$(readlink -f "$src")" = "$(readlink -f "${DEV}-part1")" ] || \
    die "смонтирован $src вместо ${DEV}-part1"
  say "  смонтирован $src"
}

do_dirs() {
  install -d -m 2775 "$MOUNT/in" "$MOUNT/out" "$MOUNT/archive"
  install -d -m 2770 "$MOUNT/tmp"
  chown "$OPERATOR:$CONTAINER_GID" "$MOUNT/in"
  chown "$CONTAINER_UID:$CONTAINER_GID" "$MOUNT/out" "$MOUNT/tmp" "$MOUNT/archive"
}

do_marker() {
  local size_ki size_gib df_out
  # -P и --output у GNU df взаимоисключающие: вместе они дают код 1. Поэтому
  # размер берётся из обычного -Pk, второй столбец второй строки — 1024-блоки.
  df_out=$(df -Pk "$MOUNT") || die "df не смог определить размер $MOUNT"
  size_ki=$(printf '%s\n' "$df_out" | awk 'NR==2{print $2}')
  case "$size_ki" in
    ''|*[!0-9]*) die "df вернул не число для $MOUNT: '${size_ki}'" ;;
  esac
  size_gib=$(( size_ki / 1048576 ))
  [ "$size_gib" -gt 0 ] || die "не удалось определить размер $MOUNT"
  printf '%s\n' "$size_gib" > "$MOUNT/.storage-size-gib"
  chmod 0444 "$MOUNT/.storage-size-gib"
  say "  маркер: $size_gib GiB"
}

do_verify() {
  local df_out
  declared=$(tr -dc '0-9' < "$MOUNT/.storage-size-gib")
  df_out=$(df -Pk "$MOUNT") || die "df не смог определить размер $MOUNT"
  total=$(printf '%s\n' "$df_out" | awk 'NR==2{print $2}')
  case "$total" in
    ''|*[!0-9]*) die "df вернул не число для $MOUNT: '${total}'" ;;
  esac
  # shellcheck disable=SC1090
  . "$SIZE_CHECK_LIB"
  size_matches "$total" "$declared" || die "размер $total KiB не совпал с маркером $declared GiB"
  findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS "$MOUNT" | sed 's/^/  /'
  df -h "$MOUNT" | tail -1 | sed 's/^/  /'
}

step "5. План выполнения"

if [ "$NEED_PARTITION" = "1" ]; then
  stage "sgdisk --zap-all $DEV" do_zap
  stage "sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:$LABEL $DEV" do_partition
else
  say "  разметка уже создана предыдущей попыткой — sgdisk не повторяется"
fi
if [ "$FS_READY" = "1" ]; then
  say "  ext4 с меткой $LABEL уже есть — wipefs и mkfs.ext4 не повторяются"
else
  stage "стереть подписи файловых систем в разделе (wipefs -a ${DEV}-part1)" do_wipe
  stage "mkfs.ext4 -m 0 -i $INODE_BYTES -L $LABEL ${DEV}-part1 (stdin от /dev/null)" do_mkfs
fi
stage "создать точку монтирования $MOUNT" do_mountpoint
stage "добавить строку UUID в $FSTAB (резервная копия, findmnt --verify, проверка после записи)" do_fstab
stage "mount $MOUNT" do_mount
stage "создать in/out/tmp/archive, выставить владельцев" do_dirs
stage "записать маркер размера из df" do_marker
stage "проверить результат" do_verify

if [ "$APPLY" != "1" ]; then
  say ""
  say "Это была примерка. Ничего не изменено."
  say "Для выполнения нужны одновременно: root, --apply и --confirm-serial $EXPECT_SERIAL"
  exit 0
fi

say ""
say "ПРОЙДЕНО: хранилище создано."
say "Дальше: ./host/check-storage.sh и ./host/diagnose-storage.sh"
