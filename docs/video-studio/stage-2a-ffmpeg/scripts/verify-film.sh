#!/bin/sh
# Проверка готового фильма: параметры, декодирование, громкость, стыки.
#
#   /tools/verify-film.sh /out/maloe-dobro/v1.mp4 [ожидаемые кадры]
#
# Проверяет не «файл создан», а что он пригоден к просмотру.
set -eu

f="${1:?нужен файл фильма}"
expect_frames="${2:-}"

[ -f "$f" ] || { printf 'ОТКАЗ: нет файла %s\n' "$f" >&2; exit 2; }

fail=0
note() { printf '  %s\n' "$1"; }
check() {
  if [ "$1" = "$2" ]; then printf '  ОК   %s: %s\n' "$3" "$2"
  else printf '  БРАК %s: %s, ожидалось %s\n' "$3" "$1" "$2"; fail=$((fail+1)); fi
}

printf '### %s\n' "$(basename "$f")"
printf '  размер: %s байт\n' "$(wc -c < "$f")"

get() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of csv=p=0 "$f" | head -1; }

vw=$(get v:0 stream=width)
vh=$(get v:0 stream=height)
vfr=$(get v:0 stream=r_frame_rate)
vnf=$(get v:0 stream=nb_frames)
vdur=$(get v:0 stream=duration)
acodec=$(get a:0 stream=codec_name)
adur=$(get a:0 stream=duration)
astart=$(get a:0 stream=start_time)
vstart=$(get v:0 stream=start_time)

check "$vw" 1280 "ширина"
check "$vh" 720 "высота"
check "$vfr" 24/1 "частота кадров"
[ -z "$expect_frames" ] || check "$vnf" "$expect_frames" "кадров"
note "длительность видео: $vdur с"
note "длительность звука: $adur с"
check "$vstart" 0.000000 "начало видео"
check "$astart" 0.000000 "начало звука"
check "$acodec" aac "кодек звука"

# Полное декодирование: любая строка в stderr на уровне error — дефект файла.
errs=$(ffmpeg -hide_banner -nostats -v error -i "$f" -f null - 2>&1 | wc -l)
check "$errs" 0 "строк ошибок при декодировании"

# Громкость и пик.
stats=$(ffmpeg -hide_banner -nostats -i "$f" -map 0:a:0 \
  -af ebur128=peak=true:framelog=quiet -f null - 2>&1)
printf '%s\n' "$stats" | grep -E '^\s+I:' | tail -1 | tr -s ' ' | sed 's/^ I:/  громкость:/' || true
printf '%s\n' "$stats" | grep -E '^\s+Peak:' | tail -1 | tr -s ' ' | sed 's/^ Peak:/  пик:/' || true

# Провалы тишины: на стыках их быть не должно.
sil=$(ffmpeg -hide_banner -nostats -i "$f" -map 0:a:0 \
  -af silencedetect=n=-45dB:d=0.3 -f null - 2>&1 | grep -c silence_start || true)
check "$sil" 0 "провалов тишины"

printf '\n  ИТОГ: %s\n' "$([ "$fail" -eq 0 ] && echo ПРИГОДЕН || echo "БРАК, замечаний $fail")"
[ "$fail" -eq 0 ]
