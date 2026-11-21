#!/usr/bin/env bash
# Инвентаризация исходников: ffprobe каждого файла, контрольные суммы, сводка.
#
#   ./scripts/inventory-sources.sh                       # /srv/video-studio-data/in
#   ./scripts/inventory-sources.sh /srv/video-studio-data/in/maloe-dobro
#
# Каталог привязывается только на чтение, поэтому оригиналы не меняются.
# Пишется только в stdout: ни манифест, ни кэш на диск не кладутся.
#
# Дубли ищутся по SHA-256 содержимого, а не по имени: Google Flow выдаёт файлы
# с похожими именами, а черновики и финальные версии легко перепутать.
# Файл без звуковой дорожки помечается отдельно — при монтаже это чаще всего
# не ошибка, а повод добавить общую дорожку.
set -euEo pipefail

STORAGE="${STORAGE:-/srv/video-studio-data}"
DIR="${1:-$STORAGE/in}"
IMAGE="${IMAGE:-video-studio/ffmpeg:8.0.1}"

die() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 2; }

[ -d "$DIR" ] || die "нет каталога $DIR"
DIR=$(cd "$DIR" && pwd)

# Файлы перечисляются на хосте: имена из Google Flow содержат пробелы и
# скобки, и разбор такого списка внутри контейнера был бы хрупким.
mapfile -d '' files < <(
  find "$DIR" -type f \
    \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.m4v' \) \
    -print0 | sort -z
)

if [ "${#files[@]}" -eq 0 ]; then
  printf 'В %s нет видеофайлов.\n' "$DIR"
  exit 0
fi

printf 'Каталог: %s\n' "$DIR"
printf 'Файлов: %s\n\n' "${#files[@]}"

# Один контейнер на файл: ffprobe и sha256 внутри образа, поэтому на хосте не
# нужны ни свои кодеки, ни доверие к ним.
#
# Каждое поле запрашивается отдельно. Один запрос с несколькими полями отдаёт
# значения в порядке структуры ffprobe, а не в порядке перечисления, и колонки
# молча съезжают: fps попадал на место pix_fmt.
probe_file() {
  local rel="$1"
  docker run --rm --network none --user 10001:10001 \
    -v "$DIR":/media:ro --entrypoint sh "$IMAGE" -c '
      f="$1"
      [ -r "$f" ] || { printf "READ_FAIL\n"; exit 0; }
      one() { ffprobe -v error "$@" 2>/dev/null | head -1; }
      dur=$(one -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
      vc=$(one -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$f")
      w=$(one -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$f")
      h=$(one -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$f")
      fps=$(one -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$f")
      pix=$(one -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$f")
      ac=$(one -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$f")
      sr=$(one -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$f")
      ch=$(one -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$f")
      size=$(stat -c %s "$f")
      sum=$(sha256sum "$f" | cut -d" " -f1)
      # Разделитель \037, а не табуляция: табуляция входит в IFS-пробелы, и
      # пустые поля при чтении схлопываются — колонки съезжают на файле без
      # звука или без видео.
      printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n" \
        "$size" "$sum" "${dur:-?}" "$vc" "$w" "$h" "$fps" "$pix" "$ac" "$sr" "$ch"
    ' sh "/media/$rel"
}

declare -a rows=()
total_sec=0
no_audio=0
fail_read=0

printf '%-52s %10s %9s %-34s %-20s\n' "ФАЙЛ" "БАЙТ" "СЕК" "ВИДЕО" "ЗВУК"
printf '%s\n' "$(printf '%0.s-' {1..132})"

for f in "${files[@]}"; do
  rel="${f#"$DIR"/}"
  out=$(probe_file "$rel")

  if [ "$out" = "READ_FAIL" ]; then
    fail_read=$((fail_read+1))
    printf '%-52s %10s\n' "$rel" "НЕТ ЧТЕНИЯ"
    continue
  fi

  IFS=$'\037' read -r size sum dur vcodec w h fps pix acodec sr ch <<< "$out"

  if [ -n "$vcodec" ]; then
    vtxt="${vcodec} ${w:-?}x${h:-?} ${fps:-?} ${pix:-?}"
  else
    vtxt="нет видеопотока"
  fi
  if [ -n "$acodec" ]; then
    atxt="${acodec} ${sr:-?}Гц ${ch:-?}кан"
  else
    atxt="нет дорожки"
    no_audio=$((no_audio+1))
  fi

  # Длительность суммируется только из чисел: у битого файла там "?".
  case "$dur" in
    ''|*[!0-9.]*) ;;
    *) total_sec=$(awk -v a="$total_sec" -v b="$dur" 'BEGIN{printf "%.3f", a+b}') ;;
  esac

  printf '%-52s %10s %9s %-34s %-20s\n' "$rel" "$size" "${dur:0:9}" "$vtxt" "$atxt"
  rows+=("$sum"$'\t'"$rel"$'\t'"$size")
done

echo
echo "== Сводка =="
printf 'Файлов: %s, суммарная длительность: %.2f с\n' "${#files[@]}" "$total_sec"
[ "$no_audio" -gt 0 ] && printf 'Без звуковой дорожки: %s\n' "$no_audio"
[ "$fail_read" -gt 0 ] && printf 'Не читаются: %s\n' "$fail_read"

echo
echo "== Дубли по содержимому =="
dups=$(printf '%s\n' "${rows[@]}" | sort | awk -F'\t' '
  { c[$1]++; names[$1]=names[$1] " " $2 }
  END { for (h in c) if (c[h] > 1) printf "%s  %s\n", substr(h,1,16), names[h] }
')
if [ -n "$dups" ]; then
  printf '%s\n' "$dups"
else
  echo "Дублей нет."
fi

echo
echo "== Контрольные суммы =="
printf '%s\n' "${rows[@]}" | sort | awk -F'\t' '{ printf "%s  %s\n", $1, $2 }'
