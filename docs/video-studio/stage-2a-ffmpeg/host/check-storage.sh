#!/usr/bin/env bash
# Состояние хранилища. Только чтение, root не нужен.
set -euo pipefail

IMAGE="${IMAGE:-/srv/video-studio-data.img}"
MOUNT="${MOUNT:-/srv/video-studio-data}"

printf '=== Хранилище %s ===\n' "$MOUNT"
if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS "$MOUNT"
  df -h "$MOUNT" | tail -1
  df -i "$MOUNT" | tail -1
else
  printf 'НЕ СМОНТИРОВАНО — рендер в дисковом режиме работать не должен\n'
fi

printf '\n=== Образ ===\n'
if [ -e "$IMAGE" ]; then
  ls -lh "$IMAGE"
  du -h --apparent-size "$IMAGE" | awk '{print "заявленный размер: "$1}'
  du -h "$IMAGE" | awk '{print "занято на диске:   "$1}'
else
  printf 'образа нет: %s\n' "$IMAGE"
fi

printf '\n=== Занятость по каталогам ===\n'
for d in in tmp out archive; do
  if [ -d "$MOUNT/$d" ]; then
    printf '%-8s %s\n' "$d" "$(du -sh "$MOUNT/$d" 2>/dev/null | cut -f1)"
  fi
done

printf '\n=== Строка fstab ===\n'
grep -F "$IMAGE" /etc/fstab || printf 'нет записи\n'

printf '\n=== Docker ===\n'
docker system df
printf 'Контейнеров: запущено %s, всего %s\n' \
  "$(docker ps -q | wc -l)" "$(docker ps -aq | wc -l)"
