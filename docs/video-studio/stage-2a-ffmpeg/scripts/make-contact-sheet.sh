#!/bin/sh
# Контактные листы для просмотра клипов покадрово.
#
# В образе студии нет шрифтов, поэтому подписи времени на кадры не наносятся.
# Вместо этого кадры идут сеткой в фиксированном порядке, а скрипт печатает
# таблицу «номер ячейки -> время». Она и есть расшифровка листа.
#
#   /tools/make-contact-sheet.sh <файл> <каталог вывода> [шаг] [колонки] [строки] [ширина]
#
# Окно задаётся переменными окружения, чтобы не путаться в кавычках:
#   START=6.5 DURATION=1.5 /tools/make-contact-sheet.sh ... 0.1 5 3 480
set -eu

f="${1:?нужен файл}"
outdir="${2:?нужен каталог вывода}"
step="${3:-0.25}"
cols="${4:-5}"
rows="${5:-8}"
w="${6:-320}"
start="${START:-0}"
dur="${DURATION:-}"

name=$(basename "$f" .mp4)
[ "$start" != "0" ] && name="${name}__${start}s"
mkdir -p "$outdir"
sheet="$outdir/${name}__grid.png"

# fps задаёт шаг выборки: 1/step кадров в секунду исходника.
rate=$(awk -v s="$step" 'BEGIN{printf "%.6f", 1/s}')

set --
[ -n "$dur" ] && set -- -ss "$start" -t "$dur"
# -ss до -i даёт точный поиск по ключевым кадрам, поэтому время в таблице
# отсчитывается от начала окна, а не от начала файла.
ffmpeg -hide_banner -nostats -v error -y "$@" -i "$f" \
  -vf "fps=${rate},scale=${w}:-1,tile=${cols}x${rows}" \
  -frames:v 1 "$sheet"

count=$((cols * rows))
printf '### %s\n' "$(basename "$f")"
printf '  лист: %s\n' "$sheet"
printf '  ячейка: шаг %s с, сетка %sx%s (%s кадров)\n' "$step" "$cols" "$rows" "$count"
i=0
while [ "$i" -lt "$count" ]; do
  t=$(awk -v i="$i" -v s="$step" -v b="$start" 'BEGIN{printf "%.2f", b + i*s}')
  printf '  %2d: %s с\n' "$((i+1))" "$t"
  i=$((i+1))
done
