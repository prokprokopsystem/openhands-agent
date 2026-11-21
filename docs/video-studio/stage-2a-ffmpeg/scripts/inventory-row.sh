#!/bin/sh
# Одна строка инвентаризации для одного файла. Печатает CSV без заголовка.
#
#   /tools/inventory-row.sh /in/21.11.2026/file.mp4
#
# Отдельный процесс на файл: при разборе сотен файлов одним циклом sh
# накапливает состояние и изредка портит путь. Здесь делить нечего.
set -eu

f="${1:?нужен файл}"
[ -f "$f" ] || { printf 'ОТКАЗ: нет файла %s\n' "$f" >&2; exit 2; }

name=$(basename "$f")
case "$name" in
  *,*|*\"*) printf 'ВНИМАНИЕ: запятая или кавычка в имени сломает CSV: %s\n' "$name" >&2 ;;
esac

ext=$(printf '%s' "$name" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')
size=$(wc -c < "$f")
hash=$(sha256sum "$f" | cut -d' ' -f1)

pick() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of csv=p=0 "$f" 2>/dev/null | head -1; }

to_fps() {
  printf '%s\n' "$1" | awk -F/ '
    NF==2 && $2+0>0 { printf "%.3f", $1/$2; exit }
    NF==1 && $1+0>0 { printf "%.3f", $1; exit }
    { printf "0" }'
}

case "$ext" in
  mp4|mov|m4v|avi|mkv|webm)
    kind=video
    width=$(pick v:0 stream=width)
    height=$(pick v:0 stream=height)
    vcodec=$(pick v:0 stream=codec_name)
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | head -1)
    dur=$(printf '%s' "${dur:-0}" | awk '{printf "%.3f", $1+0}')
    rfr=$(pick v:0 stream=r_frame_rate)
    afr=$(pick v:0 stream=avg_frame_rate)
    # У «кружков» с переменной частотой r_frame_rate равен мусорным 90000/1,
    # осмысленна только средняя частота.
    fps=$(to_fps "${afr:-0/0}")
    [ "$fps" = 0 ] && fps=$(to_fps "${rfr:-0/0}")
    rot=$(pick v:0 stream_side_data=rotation | tr -d ',')
    audio=$(pick a:0 stream=codec_name)
    [ -n "$audio" ] || audio=no
    ;;
  jpg|jpeg|png|webp|heic|gif|bmp|tif|tiff)
    kind=image
    width=$(pick v:0 stream=width)
    height=$(pick v:0 stream=height)
    rot=$(pick v:0 stream_side_data=rotation | tr -d ',')
    dur=0; fps=0; vcodec=$ext; audio=no
    ;;
  *)
    kind=other
    width=0; height=0; dur=0; fps=0; vcodec=-; audio=no; rot=0
    ;;
esac

width=${width:-0}; height=${height:-0}; rot=${rot:-0}
[ "$width" -gt 0 ] 2>/dev/null || width=0
[ "$height" -gt 0 ] 2>/dev/null || height=0

# Ориентация с учётом поворота: телефон пишет 1920x1080 и поворот 90.
if [ "$width" -eq 0 ] || [ "$height" -eq 0 ]; then
  orient=unknown
else
  w=$width; h=$height
  case "$rot" in
    90|270|-90) t=$w; w=$h; h=$t ;;
  esac
  if [ "$w" -gt "$h" ]; then orient=landscape
  elif [ "$w" -lt "$h" ]; then orient=portrait
  else orient=square; fi
fi

# Полное декодирование. Текст первой ошибки идёт в stderr: без него не понять,
# дефект это файла или предупреждение демуксера.
errs=$(ffmpeg -hide_banner -nostats -v error -i "$f" -f null - 2>&1 || true)
errn=0
if [ -n "$errs" ]; then
  errn=$(printf '%s\n' "$errs" | wc -l)
  printf '%s :: %s\n' "$name" "$(printf '%s' "$errs" | head -1)" >&2
fi

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$name" "$kind" "$ext" "$size" "$dur" "$width" "$height" "$orient" \
  "$fps" "$vcodec" "$audio" "$errn" "$hash"
