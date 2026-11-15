#!/usr/bin/env bash
# Подготовка внешнего SSD видеостудии: GPT + ext4, монтирование по UUID.
#
#   ./host/setup-ssd-storage.sh                     # примерка, ничего не меняет
#   sudo ./host/setup-ssd-storage.sh --apply --confirm-serial 24257G400264
#
# Разрушительные действия выполняются только при одновременном --apply и
# --confirm-serial с верным серийным номером. Диск адресуется через
# /dev/disk/by-id, потому что буква /dev/sdX после перезагрузки меняется.
#
# Повторное форматирование запрещено: если на разделе уже есть файловая
# система нужной метки, скрипт отказывает и требует --reformat.
set -euo pipefail

DEV="${DEV:-/dev/disk/by-id/usb-SanDisk_Extreme_55AE_323432353747343030323634-0:0}"
EXPECT_SERIAL="${EXPECT_SERIAL:-24257G400264}"
EXPECT_MODEL_SUBSTR="${EXPECT_MODEL_SUBSTR:-Extreme}"
FORBIDDEN_SERIALS="${FORBIDDEN_SERIALS:-4F0029407 181066800481}"
MIN_SIZE_BYTES="${MIN_SIZE_BYTES:-966367641600}"   # 900 GiB
MOUNT="${MOUNT:-/srv/video-studio-data}"
LABEL="${LABEL:-VIDEO_STUDIO}"
INODE_BYTES="${INODE_BYTES:-65536}"
OPERATOR="${OPERATOR:-igor}"
CONTAINER_UID="${CONTAINER_UID:-10001}"
CONTAINER_GID="${CONTAINER_GID:-10001}"
FSTAB_OPTS="rw,nosuid,nodev,noexec,noatime,nofail,errors=remount-ro,x-systemd.device-timeout=30s"

APPLY=0
REFORMAT=0
CONFIRM_SERIAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --reformat) REFORMAT=1 ;;
    --confirm-serial) CONFIRM_SERIAL="$2"; shift ;;
    --mount) MOUNT="$2"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) printf 'Неизвестный аргумент: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

# Печать запланированной команды. Никогда ничего не исполняет: план должен
# оставаться планом при любых флагах, иначе --apply выполнит команды дважды —
# на этапе печати и на этапе применения.
show() { printf '  %s\n' "$*"; }

# Права проверяются до всего остального: --apply без root не должен доходить
# ни до одного шага, который может изменить диск.
if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply --confirm-serial $EXPECT_SERIAL"
fi

step "1. Идентичность устройства"

[ -e "$DEV" ] || die "устройство $DEV не найдено — SSD не подключён или переименован"
[ -L "$DEV" ] || die "$DEV не является ссылкой by-id, отказываюсь работать с таким путём"
real=$(readlink -f "$DEV")
[ -b "$real" ] || die "$real — не блочное устройство"

# Всё дальнейшее идёт по $DEV (by-id), а не по $real: буква может измениться.
serial=$(lsblk -dno SERIAL "$DEV")
model=$(lsblk -dno MODEL "$DEV")
tran=$(lsblk -dno TRAN "$DEV")
size=$(lsblk -bdno SIZE "$DEV")

[ "$serial" = "$EXPECT_SERIAL" ] || \
  die "серийный номер '$serial' не совпадает с ожидаемым '$EXPECT_SERIAL'"
case "$model" in
  *"$EXPECT_MODEL_SUBSTR"*) ;;
  *) die "модель '$model' не содержит '$EXPECT_MODEL_SUBSTR'" ;;
esac
[ "$tran" = "usb" ] || die "шина '$tran', ожидалась usb"
[ "$size" -ge "$MIN_SIZE_BYTES" ] || die "объём $size байт меньше ожидаемых $MIN_SIZE_BYTES"

case "$(basename "$real")" in
  sda*) die "$real — системный диск, работа прекращена" ;;
esac
for s in $FORBIDDEN_SERIALS; do
  [ "$serial" != "$s" ] || die "серийный номер $s в списке запрещённых (система или AMNESIA_BACKUP)"
done

say "ПРОЙДЕНО: $DEV -> $real"
say "  модель  $model"
say "  серийный $serial"
say "  шина    $tran"
say "  объём   $(lsblk -dno SIZE "$DEV")"

step "2. Отсутствие активных монтирований"

if findmnt -S "$real" -n -o TARGET 2>/dev/null | grep -q .; then
  die "с $real уже смонтированы файловые системы: $(findmnt -S "$real" -n -o TARGET | tr '\n' ' ')"
fi
# Проверка по всему дереву: разделы могли быть смонтированы независимо.
mounted_parts=$(lsblk -pno NAME,MOUNTPOINTS "$DEV" | awk '$2 != "" {print $1}')
[ -z "$mounted_parts" ] || die "смонтированы разделы: $mounted_parts"
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$real.*"; then
  die "устройство используется как swap"
fi
say "ПРОЙДЕНО: монтирований и swap нет"

step "3. Защита от повторного форматирования"

pttype=$(lsblk -dno PTTYPE "$DEV" || true)
labels=$(lsblk -no LABEL "$DEV" | grep -v '^$' | sort -u | tr '\n' ' ')
fstypes=$(lsblk -no FSTYPE "$DEV" | grep -v '^$' | sort -u | tr '\n' ' ')

say "  таблица разделов: ${pttype:-нет}"
say "  файловые системы: ${fstypes:-нет}"
say "  метки:            ${labels:-нет}"

case "$labels" in
  *"$LABEL"*)
    [ "$REFORMAT" = "1" ] || \
      die "на устройстве уже есть метка $LABEL — хранилище, похоже, создано. Для пересоздания нужен --reformat"
    say "  ВНИМАНИЕ: --reformat разрешён, данные раздела будут уничтожены"
    ;;
esac
if [ -n "$pttype" ] && [ "$REFORMAT" != "1" ]; then
  case "$labels" in
    *"$LABEL"*) ;;
    *) say "  на устройстве есть разметка '${pttype}', но метки $LABEL нет — содержимое будет уничтожено при --apply" ;;
  esac
fi

if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  die "$MOUNT уже смонтирован — хранилище создано, повторная настройка не нужна"
fi
if [ -d "$MOUNT" ] && [ -n "$(ls -A "$MOUNT" 2>/dev/null || true)" ]; then
  die "каталог $MOUNT не пуст: там данные без монтирования, разберитесь вручную"
fi

step "4. План"

PART="${DEV}-part1"
show "sgdisk --zap-all $DEV"
show "partprobe $real"
show "udevadm settle"
show "sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:$LABEL $DEV"
show "partprobe $real"
show "udevadm settle"
show "mkfs.ext4 -m 0 -i $INODE_BYTES -L $LABEL $PART"
say "  UUID=\$(blkid -s UUID -o value $PART)"
say "  cp -a /etc/fstab /etc/fstab.bak-\$(date +%Y%m%d-%H%M%S)"
say "  echo 'UUID=<UUID> $MOUNT ext4 $FSTAB_OPTS 0 0' >> /etc/fstab"
show "systemctl daemon-reload"
show "mount $MOUNT"
show "install -d -m 2775 $MOUNT/in $MOUNT/out $MOUNT/archive"
show "install -d -m 2770 $MOUNT/tmp"
show "chown $OPERATOR:$CONTAINER_GID $MOUNT/in"
show "chown $CONTAINER_UID:$CONTAINER_GID $MOUNT/out $MOUNT/tmp $MOUNT/archive"
say "  вычисление маркера: df -Pk $MOUNT -> GiB -> $MOUNT/.storage-size-gib"
say ""
say "  Маркер считается из фактического размера, а не из номинала диска:"
say "  ограда сверяет df с объявленным числом, поэтому важно реальное значение."

if [ "$APPLY" != "1" ]; then
  say ""
  say "Это была примерка. Ничего не изменено."
  say "Для выполнения нужны одновременно два условия:"
  say "  sudo $0 --apply --confirm-serial $EXPECT_SERIAL"
  exit 0
fi

step "5. Проверки перед применением"

[ "$CONFIRM_SERIAL" = "$EXPECT_SERIAL" ] || \
  die "подтверждение не совпало: --confirm-serial '$CONFIRM_SERIAL' против ожидаемого '$EXPECT_SERIAL'"
command -v sgdisk >/dev/null || die "нет sgdisk"
command -v partprobe >/dev/null || die "нет partprobe"
command -v mkfs.ext4 >/dev/null || die "нет mkfs.ext4"

# Повторная сверка: между примеркой и применением диск могли переподключить.
[ "$(lsblk -dno SERIAL "$DEV")" = "$EXPECT_SERIAL" ] || \
  die "серийный номер изменился с момента проверки — устройство переподключено, начните заново"
findmnt -S "$real" -n -o TARGET 2>/dev/null | grep -q . && \
  die "появились монтирования на $real — повторите проверку"

step "6. Применение"

sgdisk --zap-all "$DEV"
partprobe "$real" || true
udevadm settle

sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:"$LABEL" "$DEV"
partprobe "$real" || true
udevadm settle

[ -b "$PART" ] || die "раздел $PART не появился — разметка не применилась"
mkfs.ext4 -m 0 -i "$INODE_BYTES" -L "$LABEL" "$PART"

UUID=$(blkid -s UUID -o value "$PART")
[ -n "$UUID" ] || die "не удалось получить UUID раздела"

install -d -m 0755 "$MOUNT"
stamp=$(date +%Y%m%d-%H%M%S)
cp -a /etc/fstab "/etc/fstab.bak-$stamp"
printf 'UUID=%s %s ext4 %s 0 0\n' "$UUID" "$MOUNT" "$FSTAB_OPTS" >> /etc/fstab
say "ИЗМЕНЕНО: /etc/fstab, резервная копия /etc/fstab.bak-$stamp"

systemctl daemon-reload
if ! mount "$MOUNT"; then
  say "ОШИБКА: монтирование не удалось, откатываю запись в fstab"
  sed -i "\# $MOUNT ext4 #d" /etc/fstab
  systemctl daemon-reload
  die "хранилище не смонтировано; диск размечен, данные не создавались"
fi

# Монтирование по UUID должно дать именно этот раздел.
src=$(findmnt -no SOURCE "$MOUNT")
[ "$(readlink -f "$src")" = "$(readlink -f "$PART")" ] || \
  die "смонтирован $src вместо $PART — проверка не пройдена"

install -d -m 2775 "$MOUNT/in" "$MOUNT/out" "$MOUNT/archive"
install -d -m 2770 "$MOUNT/tmp"
chown "$OPERATOR:$CONTAINER_GID" "$MOUNT/in"
chown "$CONTAINER_UID:$CONTAINER_GID" "$MOUNT/out" "$MOUNT/tmp" "$MOUNT/archive"

size_gib=$(( $(df -Pk --output=size "$MOUNT" | awk 'NR==2{print $1}') / 1048576 ))
printf '%s\n' "$size_gib" > "$MOUNT/.storage-size-gib"
chmod 0444 "$MOUNT/.storage-size-gib"

step "7. Результат"
findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS "$MOUNT"
df -h "$MOUNT" | tail -1
say "маркер: $size_gib GiB"
say "ПРОЙДЕНО: хранилище создано. Дальше: ./host/diagnose-storage.sh и ./scripts/verify-storage.sh"
