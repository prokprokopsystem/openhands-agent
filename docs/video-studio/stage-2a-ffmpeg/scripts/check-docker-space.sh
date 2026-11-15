#!/usr/bin/env bash
# Бюджет Docker перед установкой HyperFrames. Только чтение.
# Docker image и build cache лежат на общем разделе и в квоту хранилища не
# входят, поэтому их считают отдельно.
set -euo pipefail

MAX_DOCKER_GIB="${MAX_DOCKER_GIB:-60}"
MIN_HOST_FREE_GIB="${MIN_HOST_FREE_GIB:-150}"

# docker system df печатает человекочитаемые размеры: 879.2MB, 31.97GB.
gib() {
  awk -v s="$1" 'BEGIN{
    u = substr(s, length(s)-1)
    if (u == "kB") f = 1/1048576
    else if (u == "MB") f = 1/1024
    else if (u == "GB") f = 1
    else if (u == "TB") f = 1024
    else f = 0
    gsub(/[A-Za-z]/, "", s)
    printf "%d", s * f
  }'
}

field() {
  docker system df --format '{{.Type}}|{{.Size}}' | awk -F'|' -v t="$1" '$1==t{print $2}'
}

images_gib=$(gib "$(field Images)")
cache_gib=$(gib "$(field "Build Cache")")
volumes_gib=$(gib "$(field "Local Volumes")")
host_free=$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"",$1); print $1}')

total_gib=$(( images_gib + cache_gib + volumes_gib ))

printf 'Образы:       %s GiB\n' "$images_gib"
printf 'Build cache:  %s GiB\n' "$cache_gib"
printf 'Тома:         %s GiB\n' "$volumes_gib"
printf 'Итого Docker: %s GiB (предел %s GiB)\n' "$total_gib" "$MAX_DOCKER_GIB"
printf 'Свободно на /: %s GiB (нужно не меньше %s GiB)\n' "$host_free" "$MIN_HOST_FREE_GIB"

status=0
[ "$total_gib" -le "$MAX_DOCKER_GIB" ] || { printf 'НЕ ПРОЙДЕНО: Docker занимает больше %s GiB\n' "$MAX_DOCKER_GIB"; status=1; }
[ "$host_free" -ge "$MIN_HOST_FREE_GIB" ] || { printf 'НЕ ПРОЙДЕНО: на / меньше %s GiB\n' "$MIN_HOST_FREE_GIB"; status=1; }

if [ "$status" -eq 0 ]; then
  printf 'ПРОЙДЕНО: бюджета достаточно\n'
fi
exit "$status"
