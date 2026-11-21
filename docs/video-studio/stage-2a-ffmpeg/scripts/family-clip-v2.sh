#!/bin/sh
# Фрагмент нового фильма: 540x960, 30 fps, без звука.
#
#   family-clip-v2.sh <idx> <file> <kind> <start> <dur> <w> <h>
#
# Что проверено на исходниках (21.11.2026): круглой маски, рамки и значков
# Telegram в пикселях нет — это обычное квадратное видео 384x384. Кроп до 9:16
# срезал бы содержимое в 60 из 64 сцен, поэтому изображение вписывается целиком,
# а поля заполняет размытая копия той же сцены. Чтобы не читалось как «окно в
# окне», край контента растворяется в подложке мягкой маской 24 px. Фото
# абсолютно неподвижны: никакого zoompan, pan и Ken Burns.
set -eu

idx="${1:?}"; file="${2:?}"; kind="${3:?}"; start="${4:?}"; dur="${5:?}"; sw="${6:?}"; sh="${7:?}"
SRC="${SRC:-/in/21.11.2026}"
OUT="${OUT:?нужен каталог результата}"
dst=$(printf '%s/%03d.mp4' "$OUT" "$idx")
mask="${OUT%/}/mask-${idx}.png"

[ -e "$dst" ] && { printf 'ОТКАЗ: %s уже есть\n' "$dst" >&2; exit 3; }

case "$kind" in
  circle|long) fitw=540; fith=540 ;;
  photo)       fitw=540; fith=960 ;;
  *) printf 'ОТКАЗ: неизвестный тип %s\n' "$kind" >&2; exit 2 ;;
esac

# Размер полезного изображения после вписывания и его положение в кадре.
geo=$(awk -v w="$sw" -v h="$sh" -v bw="$fitw" -v bh="$fith" -v W=540 -v H=960 'BEGIN {
  s = (bw / w < bh / h) ? bw / w : bh / h;
  cw = int(w * s / 2) * 2; ch = int(h * s / 2) * 2;
  if (cw > W) cw = W; if (ch > H) ch = H;
  printf "%d %d %d %d", cw, ch, int((W - cw) / 2), int((H - ch) / 2);
}')
set -- $geo
cw=$1; ch=$2; x0=$3; y0=$4

inopt="-nostdin -hide_banner -nostats -v error -n"
enc="-color_range tv -colorspace bt709 -r 30 -c:v libx264 -preset veryfast -crf 19 -pix_fmt yuv420p"

# Мягкая маска: белый прямоугольник контента, размытый до плавного края.
ffmpeg $inopt -f lavfi -i "color=black:s=540x960:d=1" \
  -vf "drawbox=x=$x0:y=$y0:w=$cw:h=$ch:color=white:t=fill,boxblur=24:3,format=gray" \
  -frames:v 1 "$mask"

bg="scale=68:120:force_original_aspect_ratio=increase,crop=68:120,boxblur=10:4,\
scale=540:960:flags=bicubic,setsar=1,eq=brightness=-0.12:contrast=0.96:saturation=0.75"

chain="fps=30,split=2[fg][bs];\
[bs]${bg}[bgo];\
[fg]scale=${cw}:${ch}:flags=lanczos,setsar=1[fgc];\
[1:v]crop=${cw}:${ch}:${x0}:${y0},format=gray[mk];\
[fgc][mk]alphamerge[fgo];\
[bgo][fgo]overlay=$(printf '%d:%d' "$x0" "$y0"):format=auto,format=yuv420p,setparams=range=tv,setsar=1"

if [ "$kind" = photo ]; then
  ffmpeg $inopt -loop 1 -t "$dur" -i "$SRC/$file" -loop 1 -t "$dur" -i "$mask" \
    -filter_complex "$chain" $enc -t "$dur" "$dst"
else
  ffmpeg $inopt -ss "$start" -t "$dur" -i "$SRC/$file" -loop 1 -t "$dur" -i "$mask" \
    -filter_complex "$chain" $enc -t "$dur" "$dst"
fi

rm -f "$mask"
