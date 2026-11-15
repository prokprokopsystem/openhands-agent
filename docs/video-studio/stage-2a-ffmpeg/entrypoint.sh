#!/bin/sh
# Точка входа рабочего контейнера.
# Без аргументов — контейнер просто живёт, удерживая tmpfs /out.
# С аргументами — сразу отдаёт их ограничителю и ffmpeg, поэтому
# `docker compose run --rm studio -version` работает ожидаемым образом.
set -eu

if [ "$#" -eq 0 ]; then
  exec /bin/sleep infinity
fi

exec /usr/local/bin/ffmpeg-guard "$@"
