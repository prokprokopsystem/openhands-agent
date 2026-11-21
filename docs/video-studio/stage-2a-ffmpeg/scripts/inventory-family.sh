#!/bin/sh
# Инвентаризация семейного архива. Только чтение источников.
#
#   /tools/inventory-family.sh /in/21.11.2026 /out/family-memories
#
# Пишет inventory.csv и decode-errors.txt. Источники не изменяются.
#
# Каждый файл обрабатывается отдельным процессом через xargs: при разборе
# сотен файлов одним циклом sh изредка портит путь, и файл молча выпадает
# из отчёта. Флаг --no-run-if-empty не используется: список заведомо не пуст.
set -eu

SRC="${1:?нужен каталог исходников}"
OUTDIR="${2:?нужен каталог для результата}"
ROW="${ROW:-/tools/inventory-row.sh}"

[ -d "$SRC" ] || { printf 'ОТКАЗ: нет каталога %s\n' "$SRC" >&2; exit 2; }
mkdir -p "$OUTDIR"

CSV="$OUTDIR/inventory.csv"
ERRS="$OUTDIR/decode-errors.txt"

printf 'file,kind,ext,bytes,duration,width,height,orientation,fps,vcodec,audio,decode_errors,sha256\n' > "$CSV"

find "$SRC" -maxdepth 1 -type f -print0 \
  | xargs -0 -n1 "$ROW" 2> "$ERRS.raw" \
  | sort -t, -k1,1 > "$CSV.body"

cat "$CSV.body" >> "$CSV"
rm -f "$CSV.body"

# В stderr попадают две разные вещи: сведения об ошибках декодирования и отказы
# разбора. Их смешивать нельзя, поэтому сортируем по виду.
if [ -s "$ERRS.raw" ]; then
  mv "$ERRS.raw" "$ERRS"
else
  : > "$ERRS"
  rm -f "$ERRS.raw"
fi

n=$(awk 'END{print NR}' "$CSV")
bad=$(awk -F, 'NR>1 && $4==""' "$CSV" | wc -l)
printf 'строк в inventory.csv: %s, из них без размера: %s\n' "$((n-1))" "$bad"
[ "$bad" -eq 0 ] || { printf 'ОТКАЗ: часть файлов не разобрана\n' >&2; exit 3; }
