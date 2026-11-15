#!/usr/bin/env bash
# Проверка дискового хранилища видеостудии.
#
# Запускается на хосте от igor, root не нужен: все действия идут через
# контейнер и уже смонтированную файловую систему.
#
#   ./scripts/verify-storage.sh          # проверки без заполнения
#   ./scripts/verify-storage.sh --fill   # плюс проверка отказа при переполнении
#
# Источник хранилища определяется по факту (findmnt), поэтому скрипт одинаково
# работает и с loop-образом, и с разделом SSD, и с логическим томом.
#
# Проверка --fill считает число файлов из свободного места, а не из фиксированных
# 80 GiB: на хранилище 927 GiB фиксированное число не достигало предела и давало
# ложное «предел не действует».
set -euo pipefail

ROOT="${ROOT:-/home/igor/video-studio}"
MOUNT="${MOUNT:-/srv/video-studio-data}"
IMAGE="${IMAGE:-/srv/video-studio-data.img}"
MIN_GIB="${MIN_GIB:-38}"
FILL=0
[ "${1:-}" = "--fill" ] && FILL=1

DC=(docker compose -f "$ROOT/compose.disk.yaml" --project-directory "$ROOT")
pass=0
fail=0

ok() { printf '  ПРОЙДЕНО: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  НЕ ПРОЙДЕНО: %s\n' "$1"; fail=$((fail+1)); }

cd "$ROOT"

echo "== 1. Хранилище на хосте =="
source=""
if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  fstype=$(findmnt -no FSTYPE "$MOUNT")
  source=$(findmnt -no SOURCE "$MOUNT")
  size=$(df -BG --output=size "$MOUNT" | awk 'NR==2{gsub(/G/,"",$1); print $1}')
  [ "$fstype" = "ext4" ] && ok "тип файловой системы ext4" || bad "тип '$fstype' вместо ext4"
else
  bad "$MOUNT не смонтирован"
fi

case "$source" in
  /dev/mapper/*|/dev/dm-*)
    ok "источник $source — логический том" ;;
  /dev/loop*)
    [ -f "$IMAGE" ] && ok "источник $source, образ $IMAGE на месте" \
      || bad "источник $source, но файла образа $IMAGE нет" ;;
  /dev/*)
    if [ -b "$source" ]; then
      disk=$(lsblk -no PKNAME "$source" | head -1)
      ok "источник $source — раздел на /dev/${disk} (${source})"
      [ -n "$disk" ] && [ "$disk" != "sda" ] \
        && ok "раздел не на системном диске" \
        || bad "раздел на системном диске /dev/$disk"
    else
      bad "источник $source не блочное устройство"
    fi ;;
  "") ;;
  *)
    bad "неизвестный источник $source" ;;
esac

# Строка fstab ищется по точке монтирования: у loop там путь к образу,
# у раздела — UUID, поэтому поиск по IMAGE давал ложное «нет записи».
if grep -qE "[[:space:]]$MOUNT[[:space:]]" /etc/fstab 2>/dev/null; then
  ok "запись в /etc/fstab есть (монтирование после перезагрузки)"
  grep -q "nofail" /etc/fstab && ok "в fstab есть nofail" || bad "в fstab нет nofail"
else
  bad "в /etc/fstab нет записи для $MOUNT — после перезагрузки хранилище не поднимется"
fi

declared=$(tr -dc '0-9' 2>/dev/null < "$MOUNT/.storage-size-gib" || true)
if [ -n "$declared" ] && [ "$declared" -ge "$MIN_GIB" ]; then
  ok "маркер хранилища: $declared GiB"
else
  bad "маркер $MOUNT/.storage-size-gib отсутствует или меньше $MIN_GIB GiB"
fi

if [ -n "$declared" ] && [ -n "${size:-}" ]; then
  if [ "$size" -ge $(( declared * 95 / 100 )) ] && [ "$size" -le $(( declared * 105 / 100 )) ]; then
    ok "размер ${size} GiB совпадает с маркером $declared GiB"
  else
    bad "размер ${size} GiB не совпадает с маркером $declared GiB"
  fi
fi

if [ "$fail" -gt 0 ]; then
  echo
  echo "ИТОГ: ПРОЙДЕНО $pass, НЕ ПРОЙДЕНО $fail"
  echo "Дальнейшие проверки требуют смонтированного хранилища."
  exit 1
fi

echo
echo "== 2. Хранилище внутри контейнера =="
"${DC[@]}" up -d studio-disk >/dev/null
cid=$("${DC[@]}" ps -q studio-disk)
[ -n "$cid" ] || { bad "контейнер studio-disk не запустился"; exit 1; }

in_out=$(docker exec "$cid" df -BG --output=size /out | awk 'NR==2{gsub(/G/,"",$1); print $1}')
if [ "$in_out" -ge $(( declared * 95 / 100 )) ] && [ "$in_out" -le $(( declared * 105 / 100 )) ]; then
  ok "/out внутри контейнера ${in_out} GiB"
else
  bad "/out внутри контейнера ${in_out} GiB, ожидалось около $declared GiB"
fi

if docker exec "$cid" /usr/local/bin/ffmpeg-guard -version 2>&1 | grep -q 'квота .* действует'; then
  ok "ограда приняла дисковый режим"
else
  bad "ограда не подтвердила дисковый режим"
fi

if docker exec "$cid" sh -c 'touch /work/.t' 2>/dev/null; then
  bad "в /work можно писать"
else
  ok "/work только на чтение"
fi

if docker exec "$cid" sh -c 'test "$(stat -c %d /out)" = "$(stat -c %d /scratch)"'; then
  ok "временный каталог /scratch на том же хранилище"
else
  bad "/scratch вне хранилища — временные файлы уйдут вне квоты"
fi

if docker exec "$cid" sh -c 'test -r /storage/.storage-size-gib'; then
  ok "маркер виден контейнеру только на чтение"
else
  bad "контейнер не видит маркер хранилища"
fi

echo
echo "== 3. Запись и сумма файлов =="
docker exec "$cid" sh -c 'mkdir -p /out/.verify && echo probe > /out/.verify/probe' \
  && ok "запись в /out работает" || bad "запись в /out не работает"

if [ "$FILL" = "1" ]; then
  free_mib_before=$(docker exec "$cid" df -Pm /out | awk 'NR==2{print $4}')
  # Число файлов из свободного места: 4 GiB на файл плюс запас на метаданные.
  # Верхняя граница 400 защищает от бесконечного цикла при ошибке в расчёте.
  want_files=$(( free_mib_before / 4096 + 2 ))
  [ "$want_files" -gt 400 ] && want_files=400
  echo "  свободно ${free_mib_before} MiB, буду писать до $want_files файлов по 4 GiB"

  result=$(docker exec -e WANT="$want_files" "$cid" sh -c '
    set -u
    mkdir -p /out/.verify/fill
    i=0
    while [ "$i" -lt "$WANT" ]; do
      i=$((i+1))
      if ! fallocate -l 4G "/out/.verify/fill/f$i" 2>/dev/null; then
        echo "ОТКАЗ НА ФАЙЛЕ $i"
        break
      fi
    done
    used_mib=$(df -Pm /out | awk "NR==2{print \$3}")
    free_mib=$(df -Pm /out | awk "NR==2{print \$4}")
    echo "занято=${used_mib}MiB свободно=${free_mib}MiB файлов=$i"
  ' 2>&1)

  echo "  $result"
  free_mib=$(printf '%s' "$result" | sed -n 's/.*свободно=\([0-9]*\)MiB.*/\1/p')
  if printf '%s' "$result" | grep -q 'ОТКАЗ НА ФАЙЛЕ'; then
    ok "файловая система отказала при переполнении"
  else
    bad "заполнение не упёрлось в предел — предел не действует"
  fi
  if [ -n "$free_mib" ] && [ "$free_mib" -lt 8192 ]; then
    ok "свободного места осталось ${free_mib} MiB — предел реальный"
  else
    bad "после заполнения свободно ${free_mib:-?} MiB — похоже, предела нет"
  fi

  docker exec "$cid" rm -rf /out/.verify/fill
  after_mib=$(docker exec "$cid" df -Pm /out | awk 'NR==2{print $3}')
  [ "$after_mib" -lt 1024 ] && ok "после удаления занято ${after_mib} MiB" \
    || bad "после удаления занято ${after_mib} MiB — мусор остался"
fi

docker exec "$cid" rm -rf /out/.verify

echo
echo "== 4. Перезапуск контейнера =="
"${DC[@]}" restart studio-disk >/dev/null 2>&1 || true
sleep 2
cid=$("${DC[@]}" ps -q studio-disk)
in_out2=$(docker exec "$cid" df -BG --output=size /out | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$in_out" = "$in_out2" ] && ok "после перезапуска размер тот же: ${in_out2} GiB" \
  || bad "после перезапуска размер изменился: ${in_out} -> ${in_out2} GiB"
docker exec "$cid" /usr/local/bin/ffmpeg-guard -version >/dev/null 2>&1 \
  && ok "после перезапуска ограда работает" || bad "после перезапуска ограда не работает"

echo
echo "== 5. Уборка =="
"${DC[@]}" down >/dev/null 2>&1 || true
left=$("${DC[@]}" ps -aq | wc -l)
[ "$left" -eq 0 ] && ok "контейнеры проекта остановлены" || bad "остались контейнеры: $left"

echo
echo "ИТОГ: ПРОЙДЕНО $pass, НЕ ПРОЙДЕНО $fail"
[ "$fail" -eq 0 ] || exit 1
