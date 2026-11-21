#!/bin/sh
# Один нормализованный фрагмент черновика: 540x960, 30 fps, без звука.
#
#   /tools/family-clip.sh <idx> <file> <kind> <start> <dur> <w> <h>
#
# Кружок идёт в квадратном окне на размытой подложке из него же, чтобы
# вертикальный кадр не растягивал его и не резал лицо. Фото вписывается
# целиком по той же причине, с медленным приближением. Тяжёлое видео
# масштабируется в кадр целиком.
set -eu

idx="${1:?}"; file="${2:?}"; kind="${3:?}"; start="${4:?}"; dur="${5:?}"; sw="${6:?}"; sh="${7:?}"
SRC="${SRC:-/in/21.11.2026}"
OUT="${OUT:?нужен каталог результата}"
dst=$(printf '%s/%03d.mp4' "$OUT" "$idx")

[ -e "$dst" ] && { printf 'ОТКАЗ: %s уже есть\n' "$dst" >&2; exit 3; }

# -c:v до -i означал бы декодер для входа, а не кодировщик выхода.
inopt="-nostdin -hide_banner -nostats -v error -n"
enc="-r 30 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p"

case "$kind" in
  circle)
    # Подложка размывается в малом размере и растягивается: на 4 ядрах
    # это в разы дешевле блюра в полном кадре, а выглядит так же.
    vf="fps=30,split=2[bg][fg];\
[bg]scale=68:120:force_original_aspect_ratio=increase,crop=68:120,boxblur=6:2,scale=540:960,setsar=1,eq=brightness=-0.14:saturation=0.8[bgo];\
[fg]scale=456:456,setsar=1[fgo];\
[bgo][fgo]overlay=(W-w)/2:(H-h)/2:shortest=1,format=yuv420p,setsar=1"
    ffmpeg $inopt -ss "$start" -t "$dur" -i "$SRC/$file" -vf "$vf" $enc -t "$dur" "$dst"
    ;;
  long)
    vf="fps=30,scale=540:960:force_original_aspect_ratio=increase,crop=540:960,setsar=1,format=yuv420p"
    ffmpeg $inopt -ss "$start" -t "$dur" -i "$SRC/$file" -vf "$vf" $enc -t "$dur" "$dst"
    ;;
  photo)
    # Вписываем фото в кадр с сохранением пропорций, затем медленно приближаем
    # центр: так не обрезаются лица и нет растяжения.
    size=$(awk -v w="$sw" -v h="$sh" 'BEGIN{
      f = (540/w < 960/h) ? 540/w : 960/h;
      cw = int(w*f); ch = int(h*f);
      cw -= cw % 2; ch -= ch % 2;
      if (cw < 2) cw = 2; if (ch < 2) ch = 2;
      printf "%dx%d", cw, ch }')
    vf="fps=30,split=2[bg][fg];\
[bg]scale=68:120:force_original_aspect_ratio=increase,crop=68:120,boxblur=6:2,scale=540:960,setsar=1,eq=brightness=-0.16:saturation=0.8[bgo];\
[fg]scale=${size}:force_original_aspect_ratio=decrease,zoompan=z='min(1+0.0003*on,1.06)':x='iw/2-(iw/zoom)/2':y='ih/2-(ih/zoom)/2':d=1:s=${size}:fps=30,setsar=1[fgo];\
[bgo][fgo]overlay=(W-w)/2:(H-h)/2:shortest=1,format=yuv420p,setsar=1"
    ffmpeg $inopt -loop 1 -t "$dur" -i "$SRC/$file" -vf "$vf" $enc -t "$dur" "$dst"
    ;;
  *)
    printf 'ОТКАЗ: неизвестный тип %s\n' "$kind" >&2; exit 2
    ;;
esac
