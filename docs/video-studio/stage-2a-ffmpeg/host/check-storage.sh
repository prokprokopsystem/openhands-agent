#!/usr/bin/env bash
# Состояние хранилища видеостудии. Только чтение, root не нужен.
set -euo pipefail

MOUNT="${MOUNT:-/srv/video-studio-data}"
IMAGE="${IMAGE:-/srv/video-studio-data.img}"

printf '=== Хранилище %s ===\n' "$MOUNT"
source=""
if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS "$MOUNT"
  df -h "$MOUNT" | tail -1
  df -i "$MOUNT" | tail -1
  source=$(findmnt -no SOURCE "$MOUNT")
else
  printf 'НЕ СМОНТИРОВАНО — рендер в дисковом режиме работать не должен\n'
fi

printf '\n=== Тип источника ===\n'
if [ -n "$source" ]; then
  case "$source" in
    /dev/loop*)
      printf 'loop-образ: %s\n' "$source"
      printf 'файл:       %s\n' "$IMAGE"
      ;;
    /dev/mapper/*|/dev/dm-*)
      printf 'логический том: %s\n' "$source"
      ;;
    *)
      printf 'раздел диска: %s\n' "$source"
      # Показать физический диск и серийный номер: при двух USB-дисках это
      # единственный способ убедиться, что смонтирован нужный.
      disk=$(lsblk -no PKNAME "$source" 2>/dev/null | head -1)
      if [ -n "$disk" ]; then
        printf 'диск:       /dev/%s (%s, %s, серийный %s)\n' \
          "$disk" \
          "$(lsblk -dno SIZE "/dev/$disk" 2>/dev/null)" \
          "$(lsblk -dno MODEL "/dev/$disk" 2>/dev/null)" \
          "$(lsblk -dno SERIAL "/dev/$disk" 2>/dev/null)"
      fi
      ;;
  esac
else
  printf 'источник не определён\n'
fi

printf '\n=== Образ (только для loop-хранилища) ===\n'
if [ "$source" != "" ] && [ -b "$source" ] && [ "$(printf '%s' "$source" | cut -c1-9)" != "/dev/loop" ]; then
  printf 'образ не используется, хранилище на блочном устройстве\n'
elif [ -e "$IMAGE" ]; then
  if [ -f "$IMAGE" ] && [ ! -L "$IMAGE" ]; then
    ls -lh "$IMAGE"
    du -h --apparent-size "$IMAGE" | awk '{print "заявленный размер: "$1}'
    du -h "$IMAGE" | awk '{print "занято на диске:   "$1}'
  else
    printf '%s не обычный файл — пропускаю\n' "$IMAGE"
  fi
else
  printf 'образа нет: %s\n' "$IMAGE"
fi

printf '\n=== Маркер размера ===\n'
if [ -r "$MOUNT/.storage-size-gib" ]; then
  printf '%s GiB\n' "$(cat "$MOUNT/.storage-size-gib")"
else
  printf 'маркер отсутствует или недоступен\n'
fi

printf '\n=== Занятость по каталогам ===\n'
if [ -d "$MOUNT" ] && findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  for d in in tmp out archive; do
    if [ -d "$MOUNT/$d" ]; then
      printf '%-8s %s\n' "$d" "$(du -sh "$MOUNT/$d" 2>/dev/null | cut -f1)"
    fi
  done
fi

printf '\n=== Запись в fstab ===\n'
# Ищем по точке монтирования: у loop-хранилища там путь к образу, у раздела —
# UUID, поэтому поиск по IMAGE давал ложное «нет записи».
grep -n "[[:space:]]$MOUNT[[:space:]]" /etc/fstab 2>/dev/null || printf 'нет записи для %s\n' "$MOUNT"

printf '\n=== Docker ===\n'
docker system df
printf 'Контейнеров: запущено %s, всего %s\n' \
  "$(docker ps -q | wc -l)" "$(docker ps -aq | wc -l)"
