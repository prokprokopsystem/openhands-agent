#!/bin/sh
# Анализ движения внутри клипа: по кадрам считается средняя разница яркости
# с предыдущим кадром. Резкий скачок означает появление или исчезновение
# объекта — так ищутся артефакты генерации, а не «на глаз по названию файла».
#
# Запускается внутри образа студии:
#   docker run --rm -v <каталог>:/media:ro -v <скрипты>:/tools:ro \
#     --user 10001:10001 --network none --entrypoint sh \
#     video-studio/ffmpeg:8.0.1 /tools/analyze-motion.sh /media/*.mp4
#
# Окно и подробный режим задаются окружением:
#   START=6.0 DURATION=2.0 DETAIL=1 ... /tools/analyze-motion.sh /media/clip.mp4
set -eu

start="${START:-0}"
dur="${DURATION:-}"
detail="${DETAIL:-0}"

for f in "$@"; do
  printf '### %s\n' "$(basename "$f")"
  [ "$start" != "0" ] && printf '  окно: с %s с, длительность %s с\n' "$start" "${dur:-до конца}"

  set --
  [ -n "$dur" ] && set -- -ss "$start" -t "$dur"

  # tblend=difference даёт разницу соседних кадров, signalstats — её среднюю
  # яркость. metadata=print отдаёт по строке на кадр.
  ffmpeg -hide_banner -nostats "$@" -i "$f" \
    -filter_complex 'tblend=all_mode=difference,signalstats,metadata=print:file=/dev/stdout' \
    -an -f null - 2>/dev/null |
  awk '
    /^frame:/ { t = $0; sub(/.*pts_time:/, "", t); next }
    /YAVG=/  { v = $0; sub(/.*=/, "", v); print t, v }
  ' |
  DETAIL="$detail" START="$start" awk '
    { n++; t[n] = $1; v[n] = $2; s += $2
      if ($2 > mx) { mx = $2; mt = $1 }
      if ($2 < mn || n == 1) { mn = $2; nt = $1 } }
    END {
      if (!n) { print "  кадров нет"; exit }
      if (ENVIRON["DETAIL"] == "1") {
        for (i = 1; i <= n; i++) printf "  %8.3f  %.2f\n", t[i], v[i]
        print ""
      }
      m = s / n; sd = 0
      for (i = 1; i <= n; i++) sd += (v[i] - m) ^ 2
      sd = sqrt(sd / n)
      printf "  кадров: %d, средняя разница: %.2f, отклонение: %.2f, пик: %.2f в %.2f с\n", n, m, sd, mx, mt
      printf "  минимум: %.2f в %.2f с\n", mn, nt

      # Порог намеренно мягкий: артефакт может занимать малую площадь, и его
      # скачок не обязан быть самым большим в клипе.
      c = 0; line = ""
      for (i = 2; i < n; i++)
        if (v[i] > m + 2 * sd) { c++; line = line sprintf("%.2f(%.1f) ", t[i], v[i]) }
      printf "  скачки выше средней+2σ: %d%s\n", c, (c ? " -> " line : "")
    }
  '
  echo
done
