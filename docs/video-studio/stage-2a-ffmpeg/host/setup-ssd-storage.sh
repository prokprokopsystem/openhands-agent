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

# Права проверяются до любого шага, включая чтение устройства: без root
# режим --apply не имеет смысла и не должен доходить до разрушительных команд.
if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply --confirm-serial $EXPECT_SERIAL"
  [ "$CONFIRM_SERIAL" = "$EXPECT_SERIAL" ] || \
    die "подтверждение не совпало: ожидалось --confirm-serial $EXPECT_SERIAL"
fi

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

step "3. Защита от повторного форматирования"

pttype=$(lsblk -dno PTTYPE "$DEV" 2>/dev/null || true)
labels=$(lsblk -no LABEL "$DEV" 2>/dev/null | grep -v '^$' | sort -u | tr '\n' ' ' || true)
fstypes=$(lsblk -no FSTYPE "$DEV" 2>/dev/null | grep -v '^$' | sort -u | tr '\n' ' ' || true)

say "  таблица разделов: ${pttype:-нет}"
say "  файловые системы: ${fstypes:-нет}"
say "  метки:            ${labels:-нет}"

# Флага переформатирования нет намеренно. Один раз стереть чужой диск можно
# только осознанно: сначала разметка снимается вручную, затем скрипт видит
# чистое устройство. Так «--reformat по привычке» не уничтожит хранилище.
for l in $labels; do
  [ "$l" != "$LABEL" ] || die "на устройстве уже есть метка $LABEL — хранилище создано.
Пересоздание не выполняется автоматически. Если оно действительно нужно:
  1. Убедитесь, что данные не нужны.
  2. Снимите разметку вручную: sudo wipefs -a $DEV
  3. Запустите этот скрипт заново."
done
if [ -n "$pttype" ]; then
  say "  ВНИМАНИЕ: разметка '$pttype' будет уничтожена при --apply"
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

do_mkfs() {
  # Проверка «не тот диск» повторяется непосредственно перед записью: между
  # началом работы и этим шагом диск могли вынуть и вставить другой.
  [ "$(lsblk -dno SERIAL "$DEV")" = "$EXPECT_SERIAL" ] || \
    die "серийный номер изменился с момента проверки — устройство переподключено"
  findmnt -S "$real" -n -o TARGET 2>/dev/null | grep -q . && \
    die "появились монтирования на $real"
  mkfs.ext4 -m 0 -i "$INODE_BYTES" -L "$LABEL" "${DEV}-part1"
  UUID=$(blkid -s UUID -o value "${DEV}-part1")
  [ -n "$UUID" ] || die "не удалось получить UUID раздела"
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

  if ! findmnt --verify --tab-file="$tmp" >/dev/null 2>&1; then
    say "  findmnt --verify нашёл проблему в новой редакции:"
    findmnt --verify --verbose --tab-file="$tmp" 2>&1 | sed 's/^/    /' || true
    die "fstab не изменён: новая редакция не прошла проверку"
  fi
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
  # mount не создаёт точку монтирования: без этого шага mount падал бы уже
  # после разметки и mkfs, то есть откат оставлял бы отформатированный раздел.
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
  size_ki=$(df -Pk --output=size "$MOUNT" | awk 'NR==2{print $1}')
  size_gib=$(( size_ki / 1048576 ))
  [ "$size_gib" -gt 0 ] || die "не удалось определить размер $MOUNT"
  printf '%s\n' "$size_gib" > "$MOUNT/.storage-size-gib"
  chmod 0444 "$MOUNT/.storage-size-gib"
  say "  маркер: $size_gib GiB"
}

do_verify() {
  declared=$(tr -dc '0-9' < "$MOUNT/.storage-size-gib")
  total=$(df -Pk "$MOUNT" | awk 'NR==2{print $2}')
  # shellcheck disable=SC1091
  . "$(dirname "$0")/../size-check.sh"
  size_matches "$total" "$declared" || die "размер $total KiB не совпал с маркером $declared GiB"
  findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS "$MOUNT" | sed 's/^/  /'
  df -h "$MOUNT" | tail -1 | sed 's/^/  /'
}

step "5. План выполнения"

stage "sgdisk --zap-all $DEV" do_zap
stage "sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:$LABEL $DEV" do_partition
stage "mkfs.ext4 -m 0 -i $INODE_BYTES -L $LABEL ${DEV}-part1" do_mkfs
stage "добавить строку UUID в $FSTAB (резервная копия, findmnt --verify, проверка после записи)" do_fstab
stage "создать точку монтирования $MOUNT" do_mountpoint
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
