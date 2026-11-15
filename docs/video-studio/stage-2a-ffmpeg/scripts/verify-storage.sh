#!/usr/bin/env bash
# Проверка дискового хранилища видеостудии.
#
#   ./scripts/verify-storage.sh          # без заполнения, безопасно
#   ./scripts/verify-storage.sh --fill   # тест переполнения, только на тестовом хранилище
#
# Источник определяется по факту (findmnt), поэтому подходит для раздела, тома
# и loop-образа. Сверка размера с маркером использует тот же модуль
# size-check.sh, что и ограда в контейнере: допуск 1 GiB абсолютный.
#
# Режим --fill заполняет файловую систему до ENOSPC. На рабочем SSD это
# недопустимо: 927 GiB записей изнашивают диск и на время теста занимают всё
# место. Поэтому --fill работает только на маленьком тестовом хранилище и
# требует явного подтверждения человеком.
set -euEo pipefail

ROOT="${ROOT:-/home/igor/video-studio}"
PRODUCTION_MOUNT="/srv/video-studio-data"
PRODUCTION_SERIAL="24257G400264"
FILL_MAX_GIB=16
FILL_OPT_IN=".fill-test-ok"

MOUNT="${MOUNT:-$PRODUCTION_MOUNT}"
MIN_GIB="${MIN_GIB:-38}"
FILL=0
[ "${1:-}" = "--fill" ] && FILL=1

DC=(docker compose -f "$ROOT/compose.disk.yaml" --project-directory "$ROOT")
pass=0
fail=0

ok() { printf '  ПРОЙДЕНО: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  НЕ ПРОЙДЕНО: %s\n' "$1"; fail=$((fail+1)); }
die() { printf 'ОТКАЗ: %s\n' "$1" >&2; exit 2; }

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")/.." && pwd)/size-check.sh"

cd "$ROOT"

echo "== 1. Хранилище на хосте =="
source=""
if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  fstype=$(findmnt -no FSTYPE "$MOUNT")
  source=$(findmnt -no SOURCE "$MOUNT")
  total_ki=$(df -Pk "$MOUNT" | awk 'NR==2{print $2}')
  size=$(df -BG --output=size "$MOUNT" | awk 'NR==2{gsub(/G/,"",$1); print $1}')
  [ "$fstype" = "ext4" ] && ok "тип файловой системы ext4" || bad "тип '$fstype' вместо ext4"
else
  bad "$MOUNT не смонтирован"
fi

source_serial=""
case "$source" in
  /dev/mapper/*|/dev/dm-*)
    ok "источник $source — логический том" ;;
  /dev/loop*)
    ok "источник $source — loop-образ" ;;
  /dev/?*)
    if [ -b "$source" ]; then
      disk=$(lsblk -no PKNAME "$source" | head -1)
      source_serial=$(lsblk -dno SERIAL "/dev/$disk" 2>/dev/null || true)
      ok "источник $source — раздел на /dev/$disk"
      [ -n "$disk" ] && [ "$disk" != "sda" ] \
        && ok "раздел не на системном диске" \
        || bad "раздел на системном диске /dev/$disk"
      [ "$source_serial" != "$PRODUCTION_SERIAL" ] \
        && ok "это не рабочий SSD видеостудии" \
        || bad "источник указывает на рабочий SSD видеостудии"
    else
      bad "источник $source не блочное устройство"
    fi ;;
  "") ;;
  *) bad "неизвестный источник $source" ;;
esac

if grep -qE "[[:space:]]$MOUNT[[:space:]]" /etc/fstab 2>/dev/null; then
  ok "запись в /etc/fstab есть"
  grep -q "nofail" /etc/fstab && ok "в fstab есть nofail" || bad "в fstab нет nofail"
else
  bad "в /etc/fstab нет записи для $MOUNT"
fi

declared=$(tr -dc '0-9' < "$MOUNT/.storage-size-gib" 2>/dev/null || true)
if [ -n "$declared" ] && [ "$declared" -ge "$MIN_GIB" ]; then
  ok "маркер хранилища: $declared GiB"
else
  bad "маркер $MOUNT/.storage-size-gib отсутствует или меньше $MIN_GIB GiB"
fi

# Та же функция, что в ограде: допуск 1 GiB абсолютный.
if [ -n "$declared" ] && [ -n "${total_ki:-}" ]; then
  if size_matches "$total_ki" "$declared"; then
    ok "размер $(( total_ki / 1048576 )) GiB совпадает с маркером $declared GiB (допуск 1 GiB)"
  else
    bad "размер $(( total_ki / 1048576 )) GiB не совпадает с маркером $declared GiB (допуск 1 GiB)"
  fi
fi

if [ "$fail" -gt 0 ]; then
  echo
  echo "ИТОГ: ПРОЙДЕНО $pass, НЕ ПРОЙДЕНО $fail"
  echo "Дальнейшие проверки требуют смонтированного хранилища."
  exit 1
fi

# --- Проверки режима --fill: до запуска контейнера ---------------------------

if [ "$FILL" = "1" ]; then
  echo
  echo "== 0. Допуск режима --fill =="
  [ "$MOUNT" != "$PRODUCTION_MOUNT" ] || \
    die "--fill запрещён на рабочем хранилище $PRODUCTION_MOUNT.
Тест переполнения пишет до ENOSPC: на 927 GiB это износ диска и полное
занятие места. Для теста создайте маленькое отдельное хранилище, например
loop-образ 2 GiB, и укажите его: MOUNT=/mnt/storage-test ./scripts/verify-storage.sh --fill"

  [ "$source_serial" != "$PRODUCTION_SERIAL" ] || \
    die "--fill запрещён: источник указывает на рабочий SSD ($PRODUCTION_SERIAL)"

  if [ "$size" -gt "$FILL_MAX_GIB" ]; then
    die "--fill запрещён: хранилище $size GiB больше предела $FILL_MAX_GIB GiB.
Тест пишет до отказа ФС, поэтому допустим только на маленьком хранилище."
  fi
  ok "размер $size GiB не больше $FILL_MAX_GIB GiB"

  # Явное согласие человека: файл создаётся вручную в тестовом хранилище.
  [ -f "$MOUNT/$FILL_OPT_IN" ] || \
    die "--fill требует явного подтверждения: создайте файл $MOUNT/$FILL_OPT_IN
в тестовом хранилище, чтобы было видно, что это не рабочее место."
  ok "подтверждение $FILL_OPT_IN на месте"
fi

echo
echo "== 2. Хранилище внутри контейнера =="
"${DC[@]}" up -d studio-disk >/dev/null
cid=$("${DC[@]}" ps -q studio-disk)
[ -n "$cid" ] || { bad "контейнер studio-disk не запустился"; exit 1; }

in_total=$(docker exec "$cid" df -Pk /out | awk 'NR==2{print $2}')
if size_matches "$in_total" "$declared"; then
  ok "/out внутри контейнера $(( in_total / 1048576 )) GiB"
else
  bad "/out внутри контейнера $(( in_total / 1048576 )) GiB, ожидалось около $declared GiB"
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
  # Файлы по 1 GiB: на тестовом хранилище до 16 GiB это десятки файлов,
  # а не сотни, и мусор убирается быстрее.
  want_files=$(( size + 2 ))
  echo "  тестовое хранилище $size GiB, буду писать до $want_files файлов по 1 GiB"

  result=$(docker exec -e WANT="$want_files" "$cid" sh -c '
    set -u
    mkdir -p /out/.verify/fill
    i=0
    while [ "$i" -lt "$WANT" ]; do
      i=$((i+1))
      if ! fallocate -l 1G "/out/.verify/fill/f$i" 2>/dev/null; then
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
  if [ -n "$free_mib" ] && [ "$free_mib" -lt 2048 ]; then
    ok "свободного места осталось ${free_mib} MiB — предел реальный"
  else
    bad "после заполнения свободно ${free_mib:-?} MiB — похоже, предела нет"
  fi

  docker exec "$cid" rm -rf /out/.verify/fill
  after_mib=$(docker exec "$cid" df -Pm /out | awk 'NR==2{print $3}')
  [ "$after_mib" -lt 256 ] && ok "после удаления занято ${after_mib} MiB" \
    || bad "после удаления занято ${after_mib} MiB — мусор остался"
fi

docker exec "$cid" rm -rf /out/.verify

echo
echo "== 4. Перезапуск контейнера =="
"${DC[@]}" restart studio-disk >/dev/null 2>&1 || true
sleep 2
cid=$("${DC[@]}" ps -q studio-disk)
in_total2=$(docker exec "$cid" df -Pk /out | awk 'NR==2{print $2}')
[ "$in_total" = "$in_total2" ] && ok "после перезапуска размер тот же: $(( in_total2 / 1048576 )) GiB" \
  || bad "после перезапуска размер изменился: $(( in_total / 1048576 )) -> $(( in_total2 / 1048576 )) GiB"
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
