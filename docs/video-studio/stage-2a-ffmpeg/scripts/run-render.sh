#!/usr/bin/env bash
# Единственный разрешённый способ запустить ffmpeg.
#
# Два режима:
#   tmpfs (по умолчанию) — как на этапе 2а: вывод в tmpfs 1 GiB, затем публикация
#                          потоком tar в каталог out/;
#   disk  (MODE=disk)    — вывод напрямую в дисковое хранилище 40 GiB, где объём
#                          ограничивает файловая система.
#
#   ./scripts/run-render.sh -i /work/in.mp4 -c:v libx264 /out/out.mp4
#   MODE=disk ./scripts/run-render.sh -i /work/in.mp4 -c:v libx264 /out/out.mp4
set -euo pipefail

ROOT="${ROOT:-/home/igor/video-studio}"
MODE="${MODE:-tmpfs}"
STORAGE="${STORAGE:-/srv/video-studio-data}"
MIN_FREE_GIB="${MIN_FREE_GIB:-60}"
MAX_TOTAL_GIB="${MAX_TOTAL_GIB:-15}"
MIN_STORAGE_FREE_GIB="${MIN_STORAGE_FREE_GIB:-2}"

die() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 1; }

[ $# -gt 0 ] || die "нужны аргументы ffmpeg, например: -i /work/in.mp4 -c:v libx264 /out/out.mp4"
cd "$ROOT"

case "$MODE" in
  disk)
    # Проверяем именно смонтированное хранилище: если монтирование потеряно,
    # запись ушла бы на общий раздел.
    fstype=$(findmnt -no FSTYPE "$STORAGE" 2>/dev/null || true)
    [ "$fstype" = "ext4" ] || die "хранилище $STORAGE не смонтировано (тип '${fstype:-нет}')"

    storage_free=$(df -BG --output=avail "$STORAGE" | awk 'NR==2{gsub(/G/,"",$1); print $1}')
    [ "$storage_free" -ge "$MIN_STORAGE_FREE_GIB" ] || \
      die "в хранилище свободно $storage_free GiB, нужно не меньше $MIN_STORAGE_FREE_GIB"

    host_free=$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"",$1); print $1}')
    [ "$host_free" -ge 30 ] || die "на / свободно $host_free GiB, мало для работы сервисов"

    printf 'ПРОЙДЕНО: хранилище %s, свободно %s GiB, на / %s GiB\n' \
      "$STORAGE" "$storage_free" "$host_free"

    DC=(docker compose -f "$ROOT/compose.disk.yaml")
    "${DC[@]}" up -d studio-disk >/dev/null
    trap '"${DC[@]}" stop studio-disk >/dev/null 2>&1 || true' EXIT

    cid=$("${DC[@]}" ps -q studio-disk)
    [ -n "$cid" ] || die "рабочий контейнер не запустился"

    docker exec "$cid" /usr/local/bin/ffmpeg-guard "$@" || {
      code=$?
      printf 'ffmpeg завершился с кодом %s\n' "$code" >&2
      exit "$code"
    }

    used=$(docker exec "$cid" df -BG --output=used /out | awk 'NR==2{gsub(/G/,"",$1); print $1}')
    avail=$(docker exec "$cid" df -BG --output=avail /out | awk 'NR==2{gsub(/G/,"",$1); print $1}')
    printf 'ПРОЙДЕНО: в хранилище занято %s GiB, свободно %s GiB\n' "$used" "$avail"
    ;;

  tmpfs)
    [ -d "$ROOT/out" ] || die "нет каталога $ROOT/out"

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
    ;;

  *)
    die "неизвестный MODE='$MODE', допустимо tmpfs или disk"
    ;;
esac
