#!/bin/sh
# Внутренний ограничитель. Запускается как entrypoint образа, поэтому действует
# при любом вызове ffmpeg через compose, а не только при вызове из скрипта.
set -eu

OUT_DIR="${OUT_DIR:-/out}"

die() { printf 'ФФМПЕГ-ОГРАДА: %s\n' "$1" >&2; exit 78; }

[ -d "$OUT_DIR" ] || die "нет каталога $OUT_DIR"

# /out должен быть tmpfs: только он даёт жёсткий предел объёма от ядра.
fstype=$(stat -f -c %T "$OUT_DIR" 2>/dev/null || echo unknown)
if [ "$fstype" != "tmpfs" ]; then
  die "$OUT_DIR имеет тип '$fstype', ожидался tmpfs — жёсткий предел не действует"
fi

avail=$(df -Pk "$OUT_DIR" | awk 'NR==2{print $4}')
[ "${avail:-0}" -gt 0 ] || die "в $OUT_DIR нет свободного места"

printf 'ОГРАДА: %s — tmpfs, доступно %s KiB (жёсткий предел ядра)\n' \
  "$OUT_DIR" "$avail" >&2

exec /usr/local/bin/ffmpeg "$@"
