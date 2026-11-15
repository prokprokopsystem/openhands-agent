#!/bin/sh
# Внутренний ограничитель. Запускается как entrypoint образа, поэтому действует
# при любом вызове ffmpeg, а не только при вызове из скрипта.
#
# Два режима:
#   GUARD_MODE=tmpfs — рабочий каталог обязан быть tmpfs не больше 1 GiB;
#   GUARD_MODE=disk  — рабочий каталог обязан быть дисковым хранилищем: размер
#                      сверяется с маркером, который записан при создании
#                      хранилища. Так проверка не мешает расширению и ловит
#                      случай, когда mount потерян и запись ушла на общий раздел.
set -eu

GUARD_MODE="${GUARD_MODE:-tmpfs}"
OUT_DIR="${OUT_DIR:-/out}"
SCRATCH_DIR="${SCRATCH_DIR:-/scratch}"
STORAGE_MARKER="${STORAGE_MARKER:-/storage/.storage-size-gib}"

TMPFS_MAX_KI="${TMPFS_MAX_KI:-1048576}"   # 1 GiB
DISK_MIN_GIB="${DISK_MIN_GIB:-38}"

die() { printf 'ОГРАДА: %s\n' "$1" >&2; exit 78; }

fstype() { stat -f -c %T "$1" 2>/dev/null || echo unknown; }
size_ki() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print $2}'; }
free_ki() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# Подоболочка нужна, потому что на ошибку перенаправления dash завершается
# сам и не даёт вывести понятное сообщение.
writable() {
  probe="$1/.guard-probe"
  ( : > "$probe" ) 2>/dev/null || die "$1 недоступен для записи"
  rm -f "$probe"
}

[ -d "$OUT_DIR" ] || die "нет каталога $OUT_DIR"

case "$GUARD_MODE" in
  tmpfs)
    # Только tmpfs даёт жёсткий предел объёма от ядра.
    [ "$(fstype "$OUT_DIR")" = "tmpfs" ] || \
      die "$OUT_DIR имеет тип '$(fstype "$OUT_DIR")', ожидался tmpfs — жёсткий предел не действует"
    total=$(size_ki "$OUT_DIR")
    [ "${total:-0}" -gt 0 ] || die "не удалось определить размер $OUT_DIR"
    # Подмена /out на большой tmpfs хоста обошла бы предел.
    [ "$total" -le "$TMPFS_MAX_KI" ] || \
      die "$OUT_DIR размером $((total/1024)) MiB больше предела $((TMPFS_MAX_KI/1024)) MiB"
    writable "$OUT_DIR"
    printf 'ОГРАДА: %s — tmpfs %s MiB, свободно %s MiB\n' \
      "$OUT_DIR" "$((total/1024))" "$(( $(free_ki "$OUT_DIR") / 1024 ))" >&2
    ;;

  disk)
    # stat -f не различает ext2/3/4 и печатает "ext2/ext3", поэтому проверяется
    # отказ от памяти и слоя контейнера, а размер сверяется с маркером.
    type=$(fstype "$OUT_DIR")
    case "$type" in
      tmpfs|overlay|overlayfs|unknown)
        die "$OUT_DIR имеет тип '$type', ожидался диск, а не память или слой контейнера" ;;
    esac

    [ -r "$STORAGE_MARKER" ] || \
      die "нет маркера $STORAGE_MARKER: $OUT_DIR не указывает на хранилище"
    declared=$(tr -dc '0-9' < "$STORAGE_MARKER")
    [ -n "$declared" ] || die "маркер $STORAGE_MARKER пуст"
    [ "$declared" -ge "$DISK_MIN_GIB" ] || \
      die "маркер обещает $declared GiB, это меньше минимума $DISK_MIN_GIB GiB"

    total=$(size_ki "$OUT_DIR")
    [ "${total:-0}" -gt 0 ] || die "не удалось определить размер $OUT_DIR"
    expected=$(( declared * 1048576 ))
    if [ "$total" -lt $(( expected * 95 / 100 )) ] || [ "$total" -gt $(( expected * 105 / 100 )) ]; then
      die "$OUT_DIR размером $((total/1024/1024)) GiB не совпадает с объявленными $declared GiB: хранилище не смонтировано"
    fi
    writable "$OUT_DIR"

    if [ -d "$SCRATCH_DIR" ]; then
      [ "$(stat -c %d "$OUT_DIR")" = "$(stat -c %d "$SCRATCH_DIR")" ] || \
        die "$SCRATCH_DIR на другой файловой системе, временные файлы уйдут вне квоты"
      writable "$SCRATCH_DIR"
    fi

    printf 'ОГРАДА: %s — ext4 %s GiB, свободно %s GiB (квота %s GiB действует)\n' \
      "$OUT_DIR" "$((total/1024/1024))" "$(( $(free_ki "$OUT_DIR") / 1024 / 1024 ))" "$declared" >&2
    ;;

  *)
    die "неизвестный GUARD_MODE='$GUARD_MODE', допустимо tmpfs или disk"
    ;;
esac

exec /usr/local/bin/ffmpeg "$@"
