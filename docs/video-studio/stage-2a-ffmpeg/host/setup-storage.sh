#!/usr/bin/env bash
# Хранилище видеостудии на loop-образе. РЕЗЕРВНЫЙ ВАРИАНТ.
#
# Для выделенного SSD используйте host/setup-ssd-storage.sh. Этот скрипт
# остаётся на случай, когда отдельного диска нет.
#
#   ./host/setup-storage.sh              # план, ничего не меняет
#   sudo ./host/setup-storage.sh --apply # создать и смонтировать
#
# Прогон один. План и исполнение идут через одну функцию stage(): в режиме
# плана она только печатает, в --apply печатает и выполняет. Второго прохода
# нет, поэтому повторного fallocate и mkfs быть не может.
#
# Почему loop-образ, а не новый LV: раздел / занимает весь том ubuntu-vg,
# свободных экстентов нет. Уменьшение корневого LV требует размонтирования /.
set -euEo pipefail

readonly IMAGE="/srv/video-studio-data.img"
readonly MOUNT="/srv/video-studio-data"
readonly LABEL="video-data"
readonly OPERATOR="igor"
readonly CONTAINER_UID=10001
readonly CONTAINER_GID=10001
readonly FSTAB="/etc/fstab"
readonly FSTAB_OPTS="loop,rw,nosuid,nodev,noatime,nofail,x-systemd.device-timeout=30s"
readonly DEFAULT_SIZE_GIB=40
readonly MIN_HOST_FREE_GIB=60

APPLY=0
SIZE_GIB="$DEFAULT_SIZE_GIB"
BACKUP_FSTAB=""
FSTAB_MODIFIED=0
MOUNTED_BY_US=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --size-gib)
      [ $# -ge 2 ] || { printf 'ОТКАЗ: --size-gib требует значение\n' >&2; exit 2; }
      SIZE_GIB="$2"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) printf 'ОТКАЗ: неизвестный аргумент %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$SIZE_GIB" in
  ''|*[!0-9]*) printf 'ОТКАЗ: --size-gib должно быть целым числом\n' >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }
die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply"
fi

stage() {
  local desc="$1" fn="$2"
  if [ "$APPLY" = "1" ]; then
    printf '+ %s\n' "$desc"
    "$fn"
  else
    printf '  %s\n' "$desc"
  fi
}

rollback() {
  rc=$?
  # Срабатывает на любом выходе: и на необработанной ошибке (set -e), и на
  # явном die. Ошибка в условии вида «cmd || die» в ERR не попадает, поэтому
  # EXIT надёжнее, чем ERR: откат нужен в обоих случаях.
  [ "$rc" = "0" ] && exit 0
  [ "$APPLY" = "1" ] || exit "$rc"
  [ "${ROLLING_BACK:-0}" = "1" ] && exit "$rc"
  ROLLING_BACK=1
  set +e
  printf '\n=== Откат после ошибки (код %s) ===\n' "$rc" >&2

  if [ "$FSTAB_MODIFIED" = "1" ] && [ -n "$BACKUP_FSTAB" ] && [ -f "$BACKUP_FSTAB" ]; then
    cp -a "$BACKUP_FSTAB" "$FSTAB" && systemctl daemon-reload 2>/dev/null \
      && printf 'fstab восстановлен из %s\n' "$BACKUP_FSTAB" >&2
  fi

  # Живой образ не удаляется: пока файловая система смонтирована, rm образа
  # оставил бы систему с исчезнувшим под ней устройством. Сначала umount.
  if [ "$MOUNTED_BY_US" = "1" ] && findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
    umount "$MOUNT" 2>/dev/null && printf 'размонтировано %s\n' "$MOUNT" >&2 \
      || { printf 'ВНИМАНИЕ: %s остался смонтирован, образ не удаляю\n' "$MOUNT" >&2; \
           printf 'Ручной разбор: fuser -vm %s\n' "$MOUNT" >&2; exit "$rc"; }
  fi

  if [ -f "$IMAGE" ] && ! findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
    printf 'Удаляю созданный образ %s\n' "$IMAGE" >&2
    rm -f "$IMAGE"
  fi
  exit "$rc"
}
trap rollback EXIT

# См. setup-ssd-storage.sh: путь к модулю зависит от раскладки каталогов.
SIZE_CHECK_LIB=""
for c in "$(dirname "$0")/../size-check.sh" "$(dirname "$0")/../image/ffmpeg/size-check.sh"; do
  if [ -r "$c" ]; then SIZE_CHECK_LIB="$c"; break; fi
done
[ -n "$SIZE_CHECK_LIB" ] || die "не найден size-check.sh ни в корне проекта, ни в image/ffmpeg"

step "1. Проверки перед созданием"

findmnt -no TARGET "$MOUNT" >/dev/null 2>&1 && die "$MOUNT уже смонтирован — хранилище создано"
# Скрипт работает только с файлом-образом: mkfs на реальном диске — не его задача.
[ -b "$IMAGE" ] && die "$IMAGE — блочное устройство. Для диска: host/setup-ssd-storage.sh"
[ -e "$IMAGE" ] && die "$IMAGE уже существует — не перезаписываю"

if [ -d "$MOUNT" ] && [ -n "$(ls -A "$MOUNT" 2>/dev/null || true)" ]; then
  die "каталог $MOUNT не пуст, а монтирования нет: там данные на системном разделе"
fi

host_free=$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$host_free" -ge $(( SIZE_GIB + MIN_HOST_FREE_GIB )) ] || \
  die "на / свободно $host_free GiB, для $SIZE_GIB GiB нужно оставить ещё $MIN_HOST_FREE_GIB GiB"
say "ПРОЙДЕНО: на / свободно $host_free GiB, размер хранилища $SIZE_GIB GiB"

do_image() {
  install -d -m 0755 "$(dirname "$IMAGE")"
  # fallocate один раз. Файл проверяется перед форматированием: при нехватке
  # места fallocate создаёт файл меньшего размера, и mkfs на нём дал бы ФС
  # другого объёма, чем обещает маркер.
  fallocate -l "${SIZE_GIB}G" "$IMAGE" || die "fallocate не удался: мало места или ФС без поддержки"
  actual=$(( $(stat -c %s "$IMAGE") / 1073741824 ))
  [ "$actual" -eq "$SIZE_GIB" ] || die "образ $actual GiB вместо $SIZE_GIB GiB"
  chmod 0600 "$IMAGE"
}

do_mkfs() {
  mkfs.ext4 -q -m 0 -L "$LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "$IMAGE"
}

do_fstab() {
  [ -f "$FSTAB" ] || die "$FSTAB не найден"
  if grep -qE "^$IMAGE[[:space:]]+$MOUNT[[:space:]]" "$FSTAB"; then
    say "  строка для $MOUNT уже есть в fstab, не дублирую"
    return 0
  fi
  grep -qE "[[:space:]]$MOUNT[[:space:]]" "$FSTAB" && \
    die "в fstab уже есть другая запись для $MOUNT — разберитесь вручную"

  BACKUP_FSTAB="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$FSTAB" "$BACKUP_FSTAB" || die "не удалось создать резервную копию fstab"
  say "  резервная копия: $BACKUP_FSTAB"

  tmp=$(mktemp) || die "mktemp не удался"
  cat "$FSTAB" > "$tmp" || die "не удалось прочитать fstab"
  printf '%s %s ext4 %s 0 2\n' "$IMAGE" "$MOUNT" "$FSTAB_OPTS" >> "$tmp" || \
    die "не удалось дописать строку в копию fstab"

  # Ошибки достижимости, называющие только нашу строку, ожидаемы: цель
  # создаётся этим же запуском. Всё остальное — отказ.
  verify_out=$(mktemp) || die "mktemp не удался"
  # LC_ALL=C: разбор вывода ниже опирается на английские слова.
  if ! LC_ALL=C findmnt --verify --tab-file="$tmp" > "$verify_out" 2>&1; then
    unexpected=$(grep -E '\[E\]' "$verify_out" | grep -vF "$IMAGE" | grep -vF "$MOUNT" || true)
    grep -qE '(^|[^0-9])0 parse errors' "$verify_out" || unexpected="$unexpected разбор"
    if [ -n "$unexpected" ]; then
      say "  findmnt --verify нашёл проблему в новой редакции:"
      sed 's/^/    /' "$verify_out"
      rm -f "$verify_out"
      die "fstab не изменён: новая редакция не прошла проверку"
    fi
  fi
  rm -f "$verify_out"
  before=$(grep -cvE '^[[:space:]]*(#|$)' "$FSTAB" || true)
  after=$(grep -cvE '^[[:space:]]*(#|$)' "$tmp" || true)
  before=${before:-0}
  after=${after:-0}
  [ "$after" -eq $(( before + 1 )) ] || \
    die "в новой редакции $after записей вместо $(( before + 1 )) — fstab не изменён"

  if ! cat "$tmp" > "$FSTAB"; then
    cp -a "$BACKUP_FSTAB" "$FSTAB" || true
    die "не удалось записать fstab, восстановлена резервная копия"
  fi
  FSTAB_MODIFIED=1

  if ! grep -qE "^$IMAGE[[:space:]]+$MOUNT[[:space:]]" "$FSTAB"; then
    cp -a "$BACKUP_FSTAB" "$FSTAB" || true
    FSTAB_MODIFIED=0
    die "запись в fstab не подтвердилась, восстановлена резервная копия"
  fi
  say "  ИЗМЕНЕНО: $FSTAB"
  systemctl daemon-reload
  rm -f "$tmp"
}

do_mountpoint() {
  # mount не создаёт точку монтирования, а findmnt --verify считает
  # несуществующую цель ошибкой. Поэтому каталог создаётся до записи fstab.
  [ -d "$MOUNT" ] || install -d -m 0755 "$MOUNT"
}

do_mount() {
  mount "$MOUNT" || die "mount $MOUNT не удался"
  MOUNTED_BY_US=1
  src=$(findmnt -no SOURCE "$MOUNT")
  say "  смонтирован $src"
}

do_dirs() {
  install -d -m 0755 "$MOUNT/in" "$MOUNT/tmp" "$MOUNT/out" "$MOUNT/archive"
  chown "$OPERATOR:$OPERATOR" "$MOUNT/in"
  chown "$CONTAINER_UID:$CONTAINER_GID" "$MOUNT/tmp" "$MOUNT/out" "$MOUNT/archive"
}

do_marker() {
  printf '%s\n' "$SIZE_GIB" > "$MOUNT/.storage-size-gib"
  chmod 0444 "$MOUNT/.storage-size-gib"
}

do_verify() {
  total=$(df -Pk "$MOUNT" | awk 'NR==2{print $2}')
  declared=$(tr -dc '0-9' < "$MOUNT/.storage-size-gib")
  # shellcheck disable=SC1090
  . "$SIZE_CHECK_LIB"
  size_matches "$total" "$declared" || die "размер $total KiB не совпал с маркером $declared GiB"
  findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS "$MOUNT" | sed 's/^/  /'
  df -h "$MOUNT" | tail -1 | sed 's/^/  /'
}

step "2. План выполнения"

stage "fallocate -l ${SIZE_GIB}G $IMAGE (с проверкой фактического размера)" do_image
stage "mkfs.ext4 -q -m 0 -L $LABEL $IMAGE" do_mkfs
stage "создать точку монтирования $MOUNT" do_mountpoint
stage "добавить строку в $FSTAB (резервная копия, findmnt --verify, проверка после записи)" do_fstab
stage "mount $MOUNT" do_mount
stage "создать in/tmp/out/archive, выставить владельцев" do_dirs
stage "записать маркер $SIZE_GIB GiB" do_marker
stage "проверить результат" do_verify

if [ "$APPLY" != "1" ]; then
  say ""
  say "Это была примерка. Ничего не изменено."
  say "Для выполнения: sudo $0 --apply"
  exit 0
fi

say ""
say "ПРОЙДЕНО: хранилище создано. Дальше: ./host/check-storage.sh"
