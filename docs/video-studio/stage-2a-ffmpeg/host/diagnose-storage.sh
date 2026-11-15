#!/usr/bin/env bash
# Диагностика хранилища видеостудии. Только чтение: ничего не монтирует,
# не размонтирует и не восстанавливает.
#
#   ./host/diagnose-storage.sh
#
# Задача — показать факты, чтобы решение о восстановлении принимал человек.
# Автоматический `e2fsck -y` здесь не вызывается: на файловой системе с видео
# он может превратить частичную потерю в полную.
set -uo pipefail

DEV="${DEV:-/dev/disk/by-id/usb-SanDisk_Extreme_55AE_323432353747343030323634-0:0}"
MOUNT="${MOUNT:-/srv/video-studio-data}"
EXPECT_SERIAL="${EXPECT_SERIAL:-24257G400264}"

section() { printf '\n== %s ==\n' "$*"; }

section "Устройство"
if [ -e "$DEV" ]; then
  printf 'by-id:    %s -> %s\n' "$DEV" "$(readlink -f "$DEV")"
  printf 'модель:   %s\n' "$(lsblk -dno MODEL "$DEV" 2>/dev/null)"
  printf 'серийный: %s (ожидался %s)\n' "$(lsblk -dno SERIAL "$DEV" 2>/dev/null)" "$EXPECT_SERIAL"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
else
  printf 'УСТРОЙСТВО НЕ НАЙДЕНО: %s\n' "$DEV"
  printf 'Диск отключён или переименован. Монтирование по UUID от этого не страдает,\n'
  printf 'но пока диск не подключён, хранилище работать не будет.\n'
fi

section "Монтирование"
if findmnt -no SOURCE,TARGET,FSTYPE,SIZE,OPTIONS "$MOUNT" 2>/dev/null; then
  df -h "$MOUNT" | tail -1
  df -i "$MOUNT" | tail -1
  printf 'маркер: %s\n' "$(cat "$MOUNT/.storage-size-gib" 2>/dev/null || echo 'отсутствует')"
else
  printf '%s НЕ СМОНТИРОВАНО\n' "$MOUNT"
  if [ -d "$MOUNT" ] && [ -n "$(ls -A "$MOUNT" 2>/dev/null || true)" ]; then
    printf 'ВНИМАНИЕ: каталог не пуст, а монтирования нет — это осиротевшие данные на системном разделе.\n'
    du -sh "$MOUNT" 2>/dev/null
  fi
fi

section "Запись в fstab"
grep -n "$MOUNT" /etc/fstab 2>/dev/null || printf 'записи для %s в /etc/fstab нет\n' "$MOUNT"
printf '\nрезервные копии fstab:\n'
ls -1t /etc/fstab.bak-* 2>/dev/null | head -3 || printf 'нет\n'

section "Состояние systemd"
unit=$(systemd-escape -p --suffix=mount "$MOUNT" 2>/dev/null || true)
if [ -n "$unit" ]; then
  printf 'юнит: %s\n' "$unit"
  systemctl status "$unit" --no-pager -n 5 2>&1 | head -12 || true
fi
printf '\nошибки монтирования в текущей загрузке:\n'
journalctl -b --no-pager 2>/dev/null | grep -i "video-studio" | tail -5 || printf 'нет\n'

section "Ошибки USB в журнале (последние 24 часа)"
journalctl -k --since "-24 hours" --no-pager 2>/dev/null \
  | grep -iE "uas_eh|I/O error|reset SuperSpeed|disconnect|sdc" | tail -10 \
  || printf 'нет\n'

section "Что делать дальше"
printf 'Автоматическое восстановление здесь не выполняется. Порядок решения:\n\n'
printf '1. Диск виден, но не смонтирован:\n'
printf '     sudo mount %s\n' "$MOUNT"
printf '   Если mount отказал — смотрите текст ошибки ниже.\n\n'
printf '2. Ошибка "Structure needs cleaning" или журнал не восстанавливается:\n'
printf '   сначала проверка БЕЗ исправлений:\n'
printf '     sudo e2fsck -n %s-part1\n' "$DEV"
printf '   Читать вывод: он ничего не меняет. По результату решать, нужен ли ремонт,\n'
printf '   и делать резервную копию того, что читается, до любого e2fsck без -n.\n\n'
printf '3. Монтирование висит после обрыва USB:\n'
printf '     sudo mount -o ro,remount %s\n' "$MOUNT"
printf '   Принудительное umount -f/-l здесь не рекомендуется по умолчанию: оно\n'
printf '   выдёргивает файловую систему из-под процессов. Сначала понять, кто держит:\n'
printf '     sudo fuser -vm %s\n\n' "$MOUNT"
printf '4. Диск стал /dev/sdd: ничего делать не нужно, монтирование идёт по UUID.\n'
printf '   Проверить: lsblk -o NAME,SERIAL,MOUNTPOINTS\n\n'
printf '5. fsck при загрузке намеренно отключён (0 0 в fstab): проверка 927 GiB\n'
printf '   по USB заняла бы минуты и задержала старт всех сервисов. Журнал ext4\n'
printf '   восстанавливается при монтировании сам, при серьёзной ошибке mount\n'
printf '   откажет, и ограда не пустит рендер.\n'
