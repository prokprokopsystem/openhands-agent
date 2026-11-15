#!/usr/bin/env bash
# Демонтаж хранилища видеостудии. Данные по умолчанию НЕ удаляются.
#
#   ./host/remove-storage.sh                                # примерка
#   sudo ./host/remove-storage.sh --apply                   # снять монтирование и fstab
#   sudo ./host/remove-storage.sh --apply --delete-image    # плюс удалить файл образа
#
# Скрипт размонтирует хранилище и убирает его запись из /etc/fstab. Что было
# источником — файл образа или раздел диска — решается по фактическому
# состоянию, а не по настройке:
#   * размонтировать и убрать fstab можно всегда;
#   * удалить данные можно только для обычного файла-образа и только с
#     --delete-image;
#   * блочное устройство не стирается никогда.
#
# Пути заданы константами: это скрипт с root-правами и umount, подмена MOUNT
# через окружение означала бы umount произвольного каталога.
set -euo pipefail

readonly MOUNT="/srv/video-studio-data"
readonly IMAGE="/srv/video-studio-data.img"
readonly PROJECT_DIR="/home/igor/video-studio"
readonly COMPOSE="compose.disk.yaml"
readonly FSTAB="/etc/fstab"
readonly KEEP_EXTRA_GIB=1

APPLY=0
FORCE=0
DELETE_IMAGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    --delete-image) DELETE_IMAGE=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) printf 'ОТКАЗ: неизвестный аргумент %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply"
fi

# Единственная точка исполнения: в примере только печатает.
stage() {
  local desc="$1" fn="$2"
  if [ "$APPLY" = "1" ]; then
    printf '+ %s\n' "$desc"
    "$fn"
  else
    printf '  %s\n' "$desc"
  fi
}

do_stop_containers() {
  [ -d "$PROJECT_DIR" ] || { say "  каталог $PROJECT_DIR отсутствует, контейнеры не трогаю"; return 0; }
  ( cd "$PROJECT_DIR" && docker compose -f "$COMPOSE" down >/dev/null 2>&1 ) || \
    say "  ВНИМАНИЕ: compose down вернул ошибку, продолжаю"
}

do_umount() {
  umount "$MOUNT" || die "не удалось размонтировать: занято процессом. Держатель: fuser -vm $MOUNT"
  say "  размонтировано $MOUNT"
}

do_fstab() {
  BACKUP="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$FSTAB" "$BACKUP" || die "не удалось создать резервную копию fstab"
  # Строка ищется по точке монтирования: путь к образу у loop-хранилища и UUID
  # у раздела не совпадают, а точка одна и та же.
  sed -i "\# $MOUNT #d" "$FSTAB" || die "sed не смог изменить fstab"
  if grep -qE "[[:space:]]$MOUNT[[:space:]]" "$FSTAB"; then
    cp -a "$BACKUP" "$FSTAB" || true
    die "строка $MOUNT осталась в fstab, восстановлена копия $BACKUP"
  fi
  systemctl daemon-reload
  say "  ИЗМЕНЕНО: $FSTAB, резервная копия $BACKUP"
}

do_delete_image() {
  if [ -f "$IMAGE" ] && [ ! -L "$IMAGE" ]; then
    rm -f "$IMAGE"
    say "  ИЗМЕНЕНО: удалён файл образа $IMAGE"
  else
    say "  ПРОПУЩЕНО: $IMAGE не обычный файл, не удаляю"
  fi
  rmdir "$MOUNT" 2>/dev/null || true
}

# Источник нужен до размонтирования: после него findmnt уже ничего не скажет.
source=""
mounted=0
if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  mounted=1
  source=$(findmnt -no SOURCE "$MOUNT")
fi

is_partition=0
if [ -n "$source" ] && [ "$mounted" = "1" ]; then
  case "$source" in
    /dev/loop*) : ;;
    /dev/*) [ -b "$source" ] && is_partition=1 ;;
  esac
fi

fstab_has_entry=0
grep -qE "[[:space:]]$MOUNT[[:space:]]" "$FSTAB" 2>/dev/null && fstab_has_entry=1

step "1. Состояние"
say "  точка:    $MOUNT ($([ "$mounted" = 1 ] && echo смонтирована || echo не смонтирована))"
say "  источник: ${source:-неизвестен}"
say "  тип:      $([ "$is_partition" = 1 ] && echo 'раздел диска — данные сохранятся' || echo 'файл образа или неизвестно')"
say "  запись в fstab: $([ "$fstab_has_entry" = 1 ] && echo есть || echo нет)"

if [ "$DELETE_IMAGE" = "1" ] && [ "$is_partition" = "1" ]; then
  die "--delete-image для раздела диска запрещён: устройство не стирается скриптом"
fi
if [ "$DELETE_IMAGE" = "1" ] && [ -b "$IMAGE" ]; then
  die "--delete-image для блочного устройства $IMAGE запрещён"
fi

if [ "$mounted" = "1" ]; then
  used=$(df -BG --output=used "$MOUNT" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$1); print $1+0}')
  used=${used:-0}
  if [ "$used" -gt "$KEEP_EXTRA_GIB" ] && [ "$FORCE" != "1" ]; then
    die "в $MOUNT занято $used GiB; сохраните данные либо повторите с --force"
  fi
fi

# Повторный запуск после успешного демонтажа не должен ничего делать. Если же
# просят удалить образ, работа продолжается: удаление файла не зависит от
# монтирования.
if [ "$mounted" = "0" ] && [ "$fstab_has_entry" = "0" ] && \
   { [ "$DELETE_IMAGE" != "1" ] || [ ! -e "$IMAGE" ]; }; then
  say ""
  say "УЖЕ ОТКЛЮЧЕНО: $MOUNT не смонтирован, записи в fstab нет."
  exit 0
fi

step "2. План"
[ "$mounted" = "1" ] && stage "остановить контейнеры проекта ($COMPOSE down)" do_stop_containers
[ "$mounted" = "1" ] && stage "umount $MOUNT" do_umount
[ "$fstab_has_entry" = "1" ] && stage "удалить строку fstab для $MOUNT (резервная копия, проверка после записи)" do_fstab
if [ "$DELETE_IMAGE" = "1" ]; then
  stage "удалить файл образа $IMAGE" do_delete_image
else
  printf '  файл образа не удаляется (для удаления нужен --delete-image)\n'
fi
printf '  блочные устройства не стираются никогда\n'

if [ "$APPLY" != "1" ]; then
  printf '\nЭто была примерка. Ничего не изменено.\n'
  exit 0
fi

say ""
say "ПРОЙДЕНО: хранилище отключено. Данные на разделе, если он был, не тронуты."
