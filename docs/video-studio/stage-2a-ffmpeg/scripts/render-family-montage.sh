#!/bin/sh
# Сборка черновика семейного клипа: план -> фрагменты -> склейка под музыку.
#
#   /tools/render-family-montage.sh /tools/plan.csv roughcut-v1 [DRY_RUN=1]
#
# Один контролируемый проход. Существующий файл не перезаписывается.
#
# Длительности квантуются до целых кадров при 30 fps, и все смещения xfade
# считаются уже от квантованных значений. Иначе фактическая длина фрагмента
# расходится с планом на доли кадра, и переход начинает залезать за конец клипа.
set -eu

PLAN="${1:?нужен plan.csv}"
VERSION="${2:?нужен номер версии}"
DRY_RUN="${DRY_RUN:-0}"

export SRC="${SRC:-/in/21.11.2026}"
export MUSIC="${MUSIC:-/in/music.mp3}"
OUTDIR="${OUTDIR:-/out/family-memories}"
export TOOLS="${TOOLS:-/tools}"
TARGET="${TARGET:-316.108}"
GAIN="${GAIN:--2.5}"   # трек: -13.6 LUFS и пик +0.9 dBFS, после сдвига ровно -16 LUFS
FPS=30

case "$VERSION" in
  */*|*..*) printf 'ОТКАЗ: недопустимый номер версии %s\n' "$VERSION" >&2; exit 2 ;;
esac
FINAL="$OUTDIR/$VERSION.mp4"
WORK="$OUTDIR/.work-$VERSION"
[ -e "$FINAL" ] && { printf 'ОТКАЗ: %s уже существует, версия не перезаписывается\n' "$FINAL" >&2; exit 3; }

n=$(awk 'END{print NR-1}' "$PLAN")
[ "$n" -ge 2 ] || { printf 'ОТКАЗ: в плане меньше двух клипов\n' >&2; exit 4; }

if [ "$DRY_RUN" = "1" ]; then
  awk -F, -v t="$TARGET" -v fps="$FPS" '
    NR==1 {next}
    { d=$5+0; q=int(d*fps+0.5)/fps; s+=q; x+=($8+0) }
    END { printf "план: %d клипов, после квантования %.3f с, перекрытия %.3f с, итог %.3f с (цель %s)\n", NR-1, s, x, s-x, t }
  ' "$PLAN"
  printf 'DRY_RUN: рендер не запускался, файлы не созданы\n'
  exit 0
fi

mkdir -p "$WORK"
trap 'printf "ОСТАНОВ: удаляю %s\n" "$WORK"; rm -rf "$WORK"' EXIT INT TERM

# ---- подготовка: квантование, зажим переходов, граф ----
awk -F, -v fps="$FPS" -v fc="$WORK/filter.txt" -v qf="$WORK/q.csv" '
  NR==1 {next}
  { k++; idx[k]=$1; file[k]=$2; kind[k]=$3; st[k]=$4;
    d[k]=$5+0; w[k]=$6; h[k]=$7; xf[k]=$8+0 }
  END {
    for (i=1;i<=k;i++) { f=int(d[i]*fps+0.5); if (f<1) f=1; dq[i]=f/fps }
    for (i=2;i<=k;i++) {
      lim = (dq[i] < dq[i-1] ? dq[i] : dq[i-1]) * 0.4
      if (xf[i] > lim) xf[i] = (lim >= 0.35) ? int(lim*100)/100 : 0
      if (xf[i] > 0 && xf[i] < 0.35) xf[i] = 0
    }
    if (xf[1] > 0) xf[1] = 0
    print "idx,file,kind,start,dur,w,h,xfade" > qf
    for (i=1;i<=k;i++)
      printf "%d,%s,%s,%s,%.6f,%s,%s,%.2f\n", idx[i], file[i], kind[i], st[i], dq[i], w[i], h[i], xf[i] > qf
    acc = dq[1]; prev = "vi" idx[1]
    for (i=1;i<=k;i++)
      printf "%s[%d:v]settb=AVTB,fps=%d,format=yuv420p,setsar=1[vi%d];\n", (i>1?"\n":""), idx[i], fps, idx[i] > fc
    for (i=2;i<=k;i++) {
      if (xf[i] > 0) {
        off = acc - xf[i] - 0.001; if (off < 0) off = 0
        printf "[%s][vi%d]xfade=transition=fade:duration=%.3f:offset=%.3f,settb=AVTB,fps=%d,format=yuv420p,setsar=1[o%d];\n", \
          prev, idx[i], xf[i], off, fps, i > fc
        acc = acc + dq[i] - xf[i]
      } else {
        printf "[%s][vi%d]concat=n=2:v=1:a=0,settb=AVTB,fps=%d,format=yuv420p,setsar=1[o%d];\n", \
          prev, idx[i], fps, i > fc
        acc = acc + dq[i]
      }
      prev = "o" i
    }
    printf "[%s]tpad=stop_mode=clone:stop_duration=0.5[vout]\n", prev > fc
    printf "%.4f\n", acc > (fc ".len")
    printf "%.4f\n", acc
  }' "$PLAN" > "$WORK/total.txt"

TOTAL=$(cat "$WORK/total.txt")
printf 'план: %s клипов, длина видео после квантования %s с, цель %s с\n' "$n" "$TOTAL" "$TARGET"

# ---- проход 1: нормализация каждого фрагмента ----
printf 'проход 1: нормализация %s фрагментов\n' "$n"
export OUT="$WORK"

awk -F, 'NR>1 {print $1, $2, $3, $4, $5, $6, $7}' "$WORK/q.csv" \
  | xargs -n7 sh -c '"$TOOLS/family-clip.sh" "$1" "$2" "$3" "$4" "$5" "$6" "$7"' _

got=$(find "$WORK" -maxdepth 1 -name '*.mp4' | wc -l)
[ "$got" -eq "$n" ] || { printf 'ОТКАЗ: получилось %s фрагментов из %s\n' "$got" "$n" >&2; exit 5; }

# ---- проход 2: склейка и музыка ----
printf 'проход 2: склейка %s фрагментов\n' "$n"
args=$(awk -F, -v w="$WORK" 'NR>1 {printf " -i %s/%03d.mp4", w, $1}' "$WORK/q.csv")
args="$args -i $MUSIC"

# shellcheck disable=SC2086
ffmpeg -nostdin -hide_banner -v warning -stats -n $args \
  -filter_complex_script "$WORK/filter.txt" \
  -map "[vout]" -map "${n}:a:0" \
  -af "volume=${GAIN}dB" \
  -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p \
  -c:a aac -b:a 160k -ar 48000 \
  -movflags +faststart -t "$TARGET" \
  "$FINAL.part.mp4"

mv "$FINAL.part.mp4" "$FINAL"
rm -rf "$WORK"
trap - EXIT INT TERM

printf 'готово: %s\n' "$FINAL"
ls -l "$FINAL"
