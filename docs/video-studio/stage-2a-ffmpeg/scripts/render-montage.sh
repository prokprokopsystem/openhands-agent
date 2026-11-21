#!/bin/sh
# Сборка фильма «Маленькое добро» из пяти клипов Google Flow.
#
# Работает внутри образа студии: ffmpeg есть только там.
#   docker run --rm --network none --user 10001:10001 \
#     -v /srv/video-studio-data/in/maloe-dobro:/work:ro \
#     -v /srv/video-studio-data/out:/out \
#     -v <скрипты>:/tools:ro --entrypoint sh video-studio/ffmpeg:8.0.1 \
#     /tools/render-montage.sh
#
# Сухая проверка (ничего не пишет, только считает кадры):
#   ... -e DRY_RUN=1 ... /tools/render-montage.sh
#
# Клипы находятся по образцу имени, а не по полному имени: имя одного файла
# пришло с Windows с усечением «…» внутри, и жёсткая строка была бы хрупкой.
set -eu

SRC="${SRC:-/work}"
OUTDIR="${OUTDIR:-/out}"
VERSION="${VERSION:-v1}"
# Точка выхода третьей сцены. 6.291667 = 151 кадр, отсекает выдвижение подпорки.
SCENE3_OUT="${SCENE3_OUT:-6.291667}"
DRY_RUN="${DRY_RUN:-0}"
TARGET_LUFS="${TARGET_LUFS:--16}"

# Длительность видео в каждом клипе: 190 кадров при 24 fps.
CLIP_LEN=7.916667

die() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 2; }

# Один образец — один файл. Два совпадения означают неоднозначность, и тогда
# лучше остановиться, чем угадывать, какой из файлов нужен.
pick() {
  pattern="$1"
  # shellcheck disable=SC2086
  set -- $SRC/$pattern
  [ -f "$1" ] || die "не найден клип по образцу $pattern"
  [ "$#" -eq 1 ] || die "образец $pattern дал $# файлов, нужен ровно один"
  printf '%s' "$1"
}

S1=$(pick 'Robot_examining_flower_in_rain_*.mp4')
S2=$(pick 'Robot_lifting_metal_sheet_shelter_*.mp4')
S3=$(pick 'Robot_builds_rain_shelter_for_*.mp4')
S4=$(pick 'Flower_straightens_under_metal_s*.mp4')
S5=$(pick 'Aerial_view_of_industrial_city_*.mp4')

# Выравнивание громкости по измеренным уровням EBU R128 до общей цели −23 LUFS.
# Числа получены замером, а не на слух: разброс между клипами 9.6 LU.
V1=-3.4
V2=5.0
V3=4.5
V4=6.2
V5=2.3

TOTAL=$(awk -v a="$CLIP_LEN" -v b="$SCENE3_OUT" \
  'BEGIN{printf "%.6f", 4*a + b}')
FADE_OUT_START=$(awk -v t="$TOTAL" 'BEGIN{printf "%.3f", t-1.0}')

OUT="$OUTDIR/maloe-dobro/$VERSION.mp4"

printf 'Источники:\n'
printf '  1 %s\n' "$S1"
printf '  2 %s\n' "$S2"
printf '  3 %s (до %s с)\n' "$S3" "$SCENE3_OUT"
printf '  4 %s\n' "$S4"
printf '  5 %s\n' "$S5"
printf 'Итог: %s с, вывод %s\n' "$TOTAL" "$OUT"

FILTER="
[0:v]trim=0:${CLIP_LEN},setpts=PTS-STARTPTS[v0];
[0:a]atrim=0:${CLIP_LEN},asetpts=PTS-STARTPTS,volume=${V1}dB[a0];
[1:v]trim=0:${CLIP_LEN},setpts=PTS-STARTPTS[v1];
[1:a]atrim=0:${CLIP_LEN},asetpts=PTS-STARTPTS,volume=${V2}dB[a1];
[2:v]trim=0:${SCENE3_OUT},setpts=PTS-STARTPTS[v2];
[2:a]atrim=0:${SCENE3_OUT},asetpts=PTS-STARTPTS,volume=${V3}dB[a2];
[3:v]trim=0:${CLIP_LEN},setpts=PTS-STARTPTS[v3];
[3:a]atrim=0:${CLIP_LEN},asetpts=PTS-STARTPTS,volume=${V4}dB[a3];
[4:v]trim=0:${CLIP_LEN},setpts=PTS-STARTPTS[v4];
[4:a]atrim=0:${CLIP_LEN},asetpts=PTS-STARTPTS,volume=${V5}dB[a4];
[v0][a0][v1][a1][v2][a2][v3][a3][v4][a4]concat=n=5:v=1:a=1[v][a];
[v]fade=t=in:st=0:d=0.5,fade=t=out:st=${FADE_OUT_START}:d=1.0[vout];
[a]loudnorm=I=${TARGET_LUFS}:TP=-1.5:LRA=11[aout]
"

if [ "$DRY_RUN" = "1" ]; then
  # Кодирование не выполняется: проверяется только граф фильтров и тайминги.
  exec ffmpeg -hide_banner -nostats -y \
    -i "$S1" -i "$S2" -i "$S3" -i "$S4" -i "$S5" \
    -filter_complex "$FILTER" \
    -map "[vout]" -map "[aout]" -f null -
fi

mkdir -p "$OUTDIR/maloe-dobro"

ffmpeg -hide_banner -nostats -y \
  -i "$S1" -i "$S2" -i "$S3" -i "$S4" -i "$S5" \
  -filter_complex "$FILTER" \
  -map "[vout]" -map "[aout]" \
  -c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p \
  -crf 18 -preset medium -r 24 -g 48 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart \
  "$OUT"

printf '\nГотово: %s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size:stream=codec_name,width,height,r_frame_rate,nb_frames \
  -of default=noprint_wrappers=1 "$OUT"
