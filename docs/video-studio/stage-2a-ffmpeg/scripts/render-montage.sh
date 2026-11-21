#!/bin/sh
# Сборка фильма «Маленькое добро» из пяти клипов Google Flow.
#
# Запускается внутри образа студии, потому что ffmpeg есть только там:
#   docker run --rm --network none --user 10001:10001 \
#     -v /srv/video-studio-data/in/maloe-dobro:/work:ro \
#     -v /srv/video-studio-data/out:/out \
#     -v <скрипты>:/tools:ro --entrypoint sh video-studio/ffmpeg:8.0.1 \
#     /tools/render-montage.sh
#
# Сухая проверка (граф считается полностью, файл не пишется):
#   ... -e DRY_RUN=1 ... /tools/render-montage.sh
#
# Третья сцена монтируется «хвостом»: остаётся только уход робота при уже
# готовом укрытии, сам процесс установки вырезан из-за визуальных ошибок.
#
# Клипы ищутся по образцу имени: имя одного файла пришло с Windows с усечением
# «…» внутри, и жёсткая строка сломалась бы.
set -eu

SRC="${SRC:-/work}"
OUTDIR="${OUTDIR:-/out}"
VERSION="${VERSION:-v1}"
DRY_RUN="${DRY_RUN:-0}"
TARGET_LUFS="${TARGET_LUFS:--16}"

FPS=24
CLIP_FRAMES=190

# Третья сцена: кадры 164..189 включительно, то есть 26 кадров.
S3_IN_FRAME="${S3_IN_FRAME:-164}"
S3_FRAMES="${S3_FRAMES:-26}"

# Растворение 4→5. Восемь десятых секунды при 24 fps — это 19.2 кадра,
# а кадр неделим. 19 кадров (0.7917 с) ближе к 0.8 с, чем 20 (0.8333 с),
# и сохраняет точное число кадров в результате.
XFADE_FRAMES="${XFADE_FRAMES:-19}"

# Рамка на стыке без растворения. Это не «перетекание» в 0.4 с: настоящее
# перетекание укорачивает звук и расходится с видео, а удлинение требует
# увода атмосферы следующей сцены раньше её изображения. 40 мс убирают щелчок
# и перепад, не сдвигая синхронизацию ни на кадр.
AUDIO_CUT_FADE="${AUDIO_CUT_FADE:-0.04}"

die() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 2; }
conflict() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 3; }

case "$VERSION" in
  ""|*/*|*..*) die "недопустимое имя версии: '$VERSION'" ;;
esac

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

# Проверка, что запрошенный хвост существует в третьем клипе. Без неё
# опечатка в номере кадра дала бы пустой или короткий фрагмент в фильме.
have=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames \
  -of csv=p=0 "$S3" 2>/dev/null || true)
case "$have" in
  ''|*[!0-9]*) : ;;
  *) [ "$((S3_IN_FRAME + S3_FRAMES))" -le "$have" ] \
       || die "хвост сцены 3 выходит за клип: $((S3_IN_FRAME + S3_FRAMES)) кадров при $have в файле" ;;
esac

# Поправки громкости: замер EBU R128 каждого используемого фрагмента, цель −23 LUFS.
# У третьей сцены замер сделан по хвосту, а не по всему клипу: хвост громче
# на 3.2 LU (−24.3 против −27.5), и старая поправка +4.5 дБ сделала бы его громче.
V1=-3.4
V2=5.0
V3=1.3
V4=6.2
V5=2.3

calc() {
  awk -v f="$FPS" -v c="$CLIP_FRAMES" -v s3="$S3_FRAMES" \
      -v x="$XFADE_FRAMES" -v i="$S3_IN_FRAME" "$@"
}

# Кадры и секунды всех сцен и результата.
S3_IN_SEC=$(calc 'BEGIN{printf "%.6f", i/f}')
S3_SEC=$(calc 'BEGIN{printf "%.6f", s3/f}')
CLIP_SEC=$(calc 'BEGIN{printf "%.6f", c/f}')
XFADE_SEC=$(calc 'BEGIN{printf "%.6f", x/f}')
PRE_FRAMES=$(calc 'BEGIN{printf "%d", 3*c + s3}')
TOTAL_FRAMES=$(calc 'BEGIN{printf "%d", 3*c + s3 + c - x}')
TOTAL_SEC=$(calc 'BEGIN{printf "%.6f", (3*c + s3 + c - x)/f}')
XFADE_OFFSET=$(calc -v p="$PRE_FRAMES" 'BEGIN{printf "%.6f", (p - x)/f}')
FADE_OUT_START=$(calc 'BEGIN{printf "%.6f", (3*c + s3 + c - x)/f - 1.0}')
CUT_FADE_END=$(calc -v d="$CLIP_SEC" -v a="$AUDIO_CUT_FADE" 'BEGIN{printf "%.6f", d-a}')
S3_CUT_FADE_END=$(calc -v d="$S3_SEC" -v a="$AUDIO_CUT_FADE" 'BEGIN{printf "%.6f", d-a}')

OUT="$OUTDIR/maloe-dobro/$VERSION.mp4"

printf 'Источники:\n'
printf '  1 %s — кадры 0..189\n' "$S1"
printf '  2 %s — кадры 0..189\n' "$S2"
printf '  3 %s — кадры %s..%s (%s кадров, %s с)\n' \
  "$S3" "$S3_IN_FRAME" "$((S3_IN_FRAME + S3_FRAMES - 1))" "$S3_FRAMES" "$S3_SEC"
printf '  4 %s — кадры 0..189\n' "$S4"
printf '  5 %s — кадры 0..189\n' "$S5"
printf '\nРасчёт:\n'
printf '  до растворения: %s кадров, %s с\n' "$PRE_FRAMES" "$(calc -v p="$PRE_FRAMES" 'BEGIN{printf "%.6f", p/f}')"
printf '  растворение 4→5: %s кадров, %s с, начало на %s с\n' "$XFADE_FRAMES" "$XFADE_SEC" "$XFADE_OFFSET"
printf '  итог: %s кадров, %s с\n' "$TOTAL_FRAMES" "$TOTAL_SEC"
printf '  вывод: %s\n' "$OUT"

FILTER="
[0:v]trim=start_frame=0:end_frame=${CLIP_FRAMES},setpts=PTS-STARTPTS[v0];
[1:v]trim=start_frame=0:end_frame=${CLIP_FRAMES},setpts=PTS-STARTPTS[v1];
[2:v]trim=start_frame=${S3_IN_FRAME}:end_frame=$((S3_IN_FRAME + S3_FRAMES)),setpts=PTS-STARTPTS[v2];
[3:v]trim=start_frame=0:end_frame=${CLIP_FRAMES},setpts=PTS-STARTPTS[v3];
[4:v]trim=start_frame=0:end_frame=${CLIP_FRAMES},setpts=PTS-STARTPTS,fps=${FPS},settb=1/${FPS}[v4];
[v0][v1][v2][v3]concat=n=4:v=1:a=0[vcat];
[vcat]tpad=stop_mode=clone:stop=2,fps=${FPS},settb=1/${FPS}[vpre];
[vpre][v4]xfade=transition=fade:duration=${XFADE_SEC}:offset=${XFADE_OFFSET}[vmix];
[vmix]fade=t=in:st=0:d=0.5,fade=t=out:st=${FADE_OUT_START}:d=1.0[vout];
[0:a]atrim=start=0:end=${CLIP_SEC},asetpts=PTS-STARTPTS,volume=${V1}dB,afade=t=out:st=${CUT_FADE_END}:d=${AUDIO_CUT_FADE}[a0];
[1:a]atrim=start=0:end=${CLIP_SEC},asetpts=PTS-STARTPTS,volume=${V2}dB,afade=t=in:st=0:d=${AUDIO_CUT_FADE},afade=t=out:st=${CUT_FADE_END}:d=${AUDIO_CUT_FADE}[a1];
[2:a]atrim=start=${S3_IN_SEC}:end=${CLIP_SEC},asetpts=PTS-STARTPTS,volume=${V3}dB,afade=t=in:st=0:d=${AUDIO_CUT_FADE},afade=t=out:st=${S3_CUT_FADE_END}:d=${AUDIO_CUT_FADE}[a2];
[3:a]atrim=start=0:end=${CLIP_SEC},asetpts=PTS-STARTPTS,volume=${V4}dB,afade=t=in:st=0:d=${AUDIO_CUT_FADE}[a3];
[4:a]atrim=start=0:end=${CLIP_SEC},asetpts=PTS-STARTPTS,volume=${V5}dB[a4];
[a0][a1][a2][a3]concat=n=4:v=0:a=1[apre];
[apre][a4]acrossfade=d=${XFADE_SEC}:c1=tri:c2=tri[amix];
[amix]loudnorm=I=${TARGET_LUFS}:TP=-1.5:LRA=11,aresample=48000[aout]
"

if [ "$DRY_RUN" = "1" ]; then
  # Кодирование не выполняется: проверяются граф, тайминги и число кадров.
  exec ffmpeg -hide_banner -nostats \
    -i "$S1" -i "$S2" -i "$S3" -i "$S4" -i "$S5" \
    -filter_complex "$FILTER" \
    -map "[vout]" -map "[aout]" -frames:v "$TOTAL_FRAMES" -f null -
fi

# Готовая версия не перезаписывается: имя версии — это и есть защита от потери
# уже отданного результата. `-y` ниже поэтому не используется.
PART="$OUT.part.mp4"
if [ -e "$OUT" ] || [ -e "$PART" ]; then
  conflict "файл $OUT уже существует; выберите другую VERSION, прежние версии не перезаписываются"
fi

mkdir -p "$OUTDIR/maloe-dobro"
trap 'rm -f "$PART"' EXIT INT TERM

ffmpeg -hide_banner -nostats -n \
  -i "$S1" -i "$S2" -i "$S3" -i "$S4" -i "$S5" \
  -filter_complex "$FILTER" \
  -map "[vout]" -map "[aout]" \
  -frames:v "$TOTAL_FRAMES" \
  -c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p \
  -crf "${X264_CRF:-18}" -preset "${X264_PRESET:-medium}" -r "$FPS" -g 48 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart \
  "$PART"

mv "$PART" "$OUT"
trap - EXIT INT TERM

printf '\nГотово: %s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size:stream=codec_name,width,height,r_frame_rate,nb_frames \
  -of default=noprint_wrappers=1 "$OUT"
