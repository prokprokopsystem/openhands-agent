#!/usr/bin/env bash
# Создание хранилища видеостудии на loop-образе. РЕЗЕРВНЫЙ ВАРИАНТ.
#
# Для выделенного SSD используйте host/setup-ssd-storage.sh. Этот скрипт
# оставлен для случая, когда отдельного диска нет.
#
# По умолчанию НИЧЕГО НЕ МЕНЯЕТ: печатает команды и выходит. Изменения
# выполняются только с явным --apply и правами root.
#
#   ./host/setup-storage.sh              # показать план
#   sudo ./host/setup-storage.sh --apply # выполнить
#
# Почему loop-образ, а не новый LV: раздел / уже занимает весь том
# ubuntu-vg, свободных экстентов нет. Уменьшение корневого LV требует
# размонтирования /.
set -euo pipefail

IMAGE="${IMAGE:-/srv/video-studio-data.img}"
MOUNT="${MOUNT:-/srv/video-studio-data}"
SIZE_GIB="${SIZE_GIB:-40}"
LABEL="${LABEL:-video-data}"
CONTAINER_UID="${CONTAINER_UID:-10001}"
CONTAINER_GID="${CONTAINER_GID:-10001}"
OPERATOR="${OPERATOR:-igor}"
MIN_HOST_FREE_GIB="${MIN_HOST_FREE_GIB:-60}"

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --size-gib) SIZE_GIB="$2"; shift ;;
    --image) IMAGE="$2"; shift ;;
    --mount) MOUNT="$2"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'Неизвестный аргумент: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }

# run печатает команду всегда, а выполняет только с --apply.
run() {
  if [ "$APPLY" = "1" ]; then
    printf '+ %s\n' "$*"
    "$@"
  else
    printf '  %s\n' "$*"
  fi
}

if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply"
fi

say "=== Проверки перед созданием ==="
[ -b "$(findmnt -no SOURCE /)" ] || die "не удалось определить корневое устройство"

# Скрипт работает только с файлом-образом. Блочное устройство здесь означало
# бы попытку mkfs на реальном диске — это не его задача.
if [ -b "$IMAGE" ]; then
  die "$IMAGE — блочное устройство. Для диска используйте host/setup-ssd-storage.sh"
fi

if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  die "$MOUNT уже смонтирован — похоже, хранилище создано"
fi
[ -e "$IMAGE" ] && die "$IMAGE уже существует — не перезаписываю"

host_free=$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"",$1); print $1}')
need=$(( SIZE_GIB + MIN_HOST_FREE_GIB ))
[ "$host_free" -ge "$need" ] || \
  die "на / свободно $host_free GiB, для $SIZE_GIB GiB нужно оставить ещё $MIN_HOST_FREE_GIB GiB"
say "ПРОЙДЕНО: на / свободно $host_free GiB, размер хранилища $SIZE_GIB GiB"

say ""
say "=== План ==="
run install -d -m 0755 "$(dirname "$IMAGE")"
run fallocate -l "${SIZE_GIB}G" "$IMAGE"
run chmod 0600 "$IMAGE"
run mkfs.ext4 -q -m 0 -L "$LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "$IMAGE"
run install -d -m 0755 "$MOUNT"

say "  cp /etc/fstab /etc/fstab.bak-\$(date +%Y%m%d-%H%M%S)"
say "  echo '<строка ниже>' >> /etc/fstab"
say "    $IMAGE $MOUNT ext4 loop,rw,nosuid,nodev,noatime,nofail,x-systemd.device-timeout=30s 0 2"

run systemctl daemon-reload
run mount "$MOUNT"
run install -d -m 0755 "$MOUNT/in" "$MOUNT/tmp" "$MOUNT/out" "$MOUNT/archive"
run chown "$OPERATOR:$OPERATOR" "$MOUNT/in"
run chown "$CONTAINER_UID:$CONTAINER_GID" "$MOUNT/tmp" "$MOUNT/out" "$MOUNT/archive"
run sh -c "printf '%s\n' $SIZE_GIB > $MOUNT/.storage-size-gib"
run chmod 0444 "$MOUNT/.storage-size-gib"
run findmnt -no SOURCE,FSTYPE,SIZE "$MOUNT"

if [ "$APPLY" != "1" ]; then
  say ""
  say "Это была примерка. Ничего не изменено."
  say "Для выполнения: sudo $0 --apply"
  exit 0
fi

say ""
say "=== Применение ==="
stamp=$(date +%Y%m%d-%H%M%S)
install -d -m 0755 "$(dirname "$IMAGE")"
fallocate -l "${SIZE_GIB}G" "$IMAGE"
chmod 0600 "$IMAGE"
mkfs.ext4 -q -m 0 -L "$LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "$IMAGE"
install -d -m 0755 "$MOUNT"

cp -a /etc/fstab "/etc/fstab.bak-$stamp"
line="$IMAGE $MOUNT ext4 loop,rw,nosuid,nodev,noatime,nofail,x-systemd.device-timeout=30s 0 2"
grep -qxF "$line" /etc/fstab || printf '%s\n' "$line" >> /etc/fstab
say "ИЗМЕНЕНО: /etc/fstab, резервная копия /etc/fstab.bak-$stamp"

systemctl daemon-reload
if ! mount "$MOUNT"; then
  say "ОШИБКА: монтирование не удалось, откатываю изменения"
  sed -i "\#^$IMAGE $MOUNT #d" /etc/fstab
  systemctl daemon-reload
  rm -f "$IMAGE"
  die "хранилище не создано, изменения отменены"
fi

install -d -m 0755 "$MOUNT/in" "$MOUNT/tmp" "$MOUNT/out" "$MOUNT/archive"
chown "$OPERATOR:$OPERATOR" "$MOUNT/in"
chown "$CONTAINER_UID:$CONTAINER_GID" "$MOUNT/tmp" "$MOUNT/out" "$MOUNT/archive"
# Маркер размера: ограда в контейнере сверяет с ним df и так замечает, что
# хранилище не смонтировано. Обновляется скриптом расширения.
printf '%s\n' "$SIZE_GIB" > "$MOUNT/.storage-size-gib"
chmod 0444 "$MOUNT/.storage-size-gib"

say ""
say "=== Результат ==="
findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS "$MOUNT"
df -h "$MOUNT" | tail -1
say "ПРОЙДЕНО: хранилище создано. Дальше: ./scripts/verify-storage.sh"
