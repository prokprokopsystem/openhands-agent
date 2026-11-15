#!/usr/bin/env bash
# Предварительная проверка диска перед любым запуском ffmpeg, который пишет файлы.
# Не является квотой: проверяет свободное место и объём out/ в момент запуска.
set -euo pipefail

ROOT="${ROOT:-/home/igor/video-studio}"
MIN_FREE_GIB="${MIN_FREE_GIB:-60}"
MAX_OUT_GIB="${MAX_OUT_GIB:-15}"

fail() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 1; }

[ -d "$ROOT/out" ] || fail "нет каталога $ROOT/out"

free_gib=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
out_bytes=$(du -sb "$ROOT/out" | cut -f1)
out_gib=$(( out_bytes / 1073741824 ))

printf 'Свободно на разделе: %s GiB (порог %s)\n' "$free_gib" "$MIN_FREE_GIB"
printf 'Занято в out/: %s GiB (порог %s)\n' "$out_gib" "$MAX_OUT_GIB"

[ "$free_gib" -ge "$MIN_FREE_GIB" ] || fail "мало свободного места на диске"
[ "$out_gib" -le "$MAX_OUT_GIB" ] || fail "каталог out/ превысил разрешённый объём, очистите его"

if docker compose -f "$ROOT/compose.yaml" ps --quiet 2>/dev/null | grep -q .; then
  fail "контейнер video-studio уже запущен"
fi

printf 'ПРОЙДЕНО\n'
