#!/usr/bin/env bash
# Проверка установки: конфигурация Compose, ограничения ресурсов и бинарники.
# Не читает медиа и не запускает кодирование.
set -euo pipefail

ROOT="${ROOT:-/home/igor/video-studio}"
cd "$ROOT"

echo '== docker compose config =='
docker compose config --quiet && echo 'ПРОЙДЕНО: конфигурация корректна'

echo
echo '== ffmpeg -version =='
docker compose run --rm --no-deps --entrypoint /usr/local/bin/ffmpeg ffmpeg -version

echo
echo '== ffprobe -version =='
docker compose run --rm --no-deps --entrypoint /usr/local/bin/ffprobe ffmpeg -version

echo
echo '== обязательные кодеки и фильтры =='
docker compose run --rm --no-deps --entrypoint /bin/sh ffmpeg -c '
set -e
need_enc="libx264 aac libmp3lame"
need_flt="concat xfade fade scale overlay amix volume loudnorm atempo setpts fps crop pad"
for e in $need_enc; do
  /usr/local/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $e " \
    && echo "encoder $e: OK" || { echo "encoder $e: MISSING"; exit 1; }
done
for f in $need_flt; do
  /usr/local/bin/ffmpeg -hide_banner -filters 2>/dev/null | awk "{print \$2}" | grep -qx "$f" \
    && echo "filter $f: OK" || { echo "filter $f: MISSING"; exit 1; }
done
echo "user: $(id -u):$(id -g)"
'

echo
echo '== ffmpeg -buildconf (первые строки) =='
docker compose run --rm --no-deps ffmpeg -hide_banner -buildconf | head -25
