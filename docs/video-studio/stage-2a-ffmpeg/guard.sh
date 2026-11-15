#!/bin/sh
# Внутренний ограничитель. Запускается как entrypoint образа, поэтому действует
# при любом вызове ffmpeg, а не только при вызове из скрипта.
set -eu

OUT_DIR="${OUT_DIR:-/out}"
MAX_KI_BYTES="${MAX_KI_BYTES:-1048576}"

die() { printf 'ОГРАДА: %s\n' "$1" >&2; exit 78; }

[ -d "$OUT_DIR" ] || die "нет каталога $OUT_DIR"

# /out должен быть tmpfs: только он даёт жёсткий предел объёма от ядра.
fstype=$(stat -f -c %T "$OUT_DIR" 2>/dev/null || echo unknown)
[ "$fstype" = "tmpfs" ] || \
  die "$OUT_DIR имеет тип '$fstype', ожидался tmpfs — жёсткий предел не действует"

# Подмена /out на большой tmpfs хоста обошла бы предел, поэтому размер сверяется.
total=$(df -Pk "$OUT_DIR" | awk 'NR==2{print $2}')
[ "${total:-0}" -gt 0 ] || die "не удалось определить размер $OUT_DIR"
[ "$total" -le "$MAX_KI_BYTES" ] || \
  die "$OUT_DIR размером $((total/1024)) MiB больше предела $((MAX_KI_BYTES/1024)) MiB"

probe="$OUT_DIR/.guard-probe"
# Подоболочка нужна, потому что на ошибку перенаправления dash завершается
# сам и не даёт вывести понятное сообщение.
if ! ( : > "$probe" ) 2>/dev/null; then
  die "$OUT_DIR недоступен для записи"
fi
rm -f "$probe"

printf 'ОГРАДА: %s — tmpfs %s MiB, доступно %s KiB\n' \
  "$OUT_DIR" "$((total/1024))" "$(df -Pk "$OUT_DIR" | awk 'NR==2{print $4}')" >&2

exec /usr/local/bin/ffmpeg "$@"
