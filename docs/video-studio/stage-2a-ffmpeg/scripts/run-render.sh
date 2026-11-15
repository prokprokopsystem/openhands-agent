#!/usr/bin/env bash
# Единственный разрешённый способ получить файл на диск хоста.
#
# 1. Проверяет свободное место и текущий объём out/.
# 2. Поднимает рабочий контейнер с tmpfs /out (жёсткий предел ядра 1 GiB).
# 3. Запускает ffmpeg внутри через ограничитель образа.
# 4. Сверяет объём результата с остатком лимита.
# 5. Забирает результат одним docker cp и гасит контейнер (tmpfs очищается).
set -euo pipefail

ROOT="${ROOT:-/home/igor/video-studio}"
MIN_FREE_GIB="${MIN_FREE_GIB:-60}"
MAX_TOTAL_GIB="${MAX_TOTAL_GIB:-15}"

die() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 1; }

[ $# -gt 0 ] || die "нужны аргументы ffmpeg, например: -i /work/in.mp4 -c:v libx264 /out/out.mp4"
[ -d "$ROOT/out" ] || die "нет каталога $ROOT/out"
cd "$ROOT"

free_gib=$(df -BG --output=avail "$ROOT" | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$free_gib" -ge "$MIN_FREE_GIB" ] || die "свободно $free_gib GiB, нужно не меньше $MIN_FREE_GIB"

total_bytes=$(du -sb "$ROOT/out" | awk '{print $1}')
total_gib=$(( total_bytes / 1073741824 ))
[ "$total_gib" -le "$MAX_TOTAL_GIB" ] || die "каталог out/ занят $total_gib GiB, предел $MAX_TOTAL_GIB"

printf 'ПРОЙДЕНО: свободно %s GiB, out/ занят %s GiB\n' "$free_gib" "$total_gib"

docker compose up -d studio >/dev/null
trap 'docker compose stop studio >/dev/null 2>&1 || true' EXIT

cid=$(docker compose ps -q studio)
[ -n "$cid" ] || die "рабочий контейнер не запустился"

docker exec "$cid" /usr/local/bin/ffmpeg-guard "$@"
code=$?
if [ "$code" != "0" ]; then
  printf 'ffmpeg завершился с кодом %s, публикация не выполнена\n' "$code" >&2
  exit "$code"
fi

produced=$(docker exec "$cid" sh -c 'du -sb /out 2>/dev/null | cut -f1')
produced=${produced:-0}
if [ "$produced" -eq 0 ]; then
  printf 'В /out нет файлов — ffmpeg ничего не создал\n' >&2
  exit 1
fi

allow_bytes=$(( (MAX_TOTAL_GIB - total_gib) * 1073741824 ))
if [ "$produced" -gt "$allow_bytes" ]; then
  die "результат $produced байт не помещается в остаток лимита $allow_bytes; очистите out/ и повторите"
fi

# docker cp в этом runtime не видит tmpfs внутри контейнера, поэтому публикуем
# потоком tar. Объём ограничен содержимым /out, а его предел задан ядром.
docker exec "$cid" tar -cf - -C /out . \
  | tar -xf - -C "$ROOT/out" --no-same-owner --no-same-permissions

after=$(du -sb "$ROOT/out" | awk '{print $1}')
if [ "$after" -le "$total_bytes" ]; then
  printf 'Публикация не дала файлов: было %s байт, стало %s\n' "$total_bytes" "$after" >&2
  exit 1
fi

printf 'Опубликовано: %s байт. Всего в out/: %s байт (предел %s GiB)\n' \
  "$produced" "$after" "$MAX_TOTAL_GIB"
