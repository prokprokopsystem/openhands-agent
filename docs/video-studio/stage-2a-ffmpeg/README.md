# Среда видеостудии: FFmpeg / ffprobe и хранилище

Каталог развёрнут на mini-server в `/home/igor/video-studio`. Имя `stage-2a` —
историческое: здесь лежит среда этапа 2а и подготовленная схема хранения этапа
2в. Рендер не входит в этот каталог: здесь только среда и правила.

## Состав

| Файл | Назначение |
|---|---|
| `Dockerfile`, `guard.sh`, `entrypoint.sh` | образ `video-studio/ffmpeg:8.0.1`; `entrypoint.sh` без аргументов держит контейнер живым, с аргументами передаёт их ограде и ffmpeg |
| `compose.yaml` | режим `tmpfs`: изоляция, лимиты, `/out` в памяти 1 GiB |
| `compose.disk.yaml` | режим `disk`: сервис `studio-disk` с хранилищем `/srv/video-studio-data` 40 GiB |
| `scripts/run-render.sh` | единственный разрешённый способ запуска; режим задаётся `MODE=tmpfs\|disk` |
| `scripts/verify.sh` | 25 проверок установки в режиме `tmpfs` |
| `scripts/verify-storage.sh` | проверки хранилища, включая тест переполнения (`--fill`) |
| `scripts/check-docker-space.sh` | бюджет Docker перед установкой HyperFrames |
| `host/setup-storage.sh` | привилегированное создание хранилища; без `--apply` только примерка |
| `host/resize-storage.sh` | расширение без остановки контейнеров |
| `host/remove-storage.sh` | удаление хранилища с резервной копией `fstab` |
| `host/check-storage.sh` | состояние хранилища, только чтение |

## Два режима

### tmpfs — этап 2а, работает сейчас

```
ffmpeg --> tmpfs /out (1 GiB, предел ядра) --> tar-поток --> ./out на диске
```

1. Каталог хоста **не смонтирован** в контейнер: у процесса монтажа нет цели для
   записи на диск — ни в `/srv`, ни в Paperless, ни в Nextcloud.
2. Всё, что создаёт ffmpeg, попадает в `tmpfs /out` 1 GiB. Предел задаёт ядро:
   при переполнении запись прекращается.
3. Дополнительно действует `RLIMIT_FSIZE` = 1 GiB на один файл.
4. Публикация — поток `tar` из `tmpfs` в `./out`; объём ограничен содержимым
   `tmpfs`.
5. `run-render.sh` отказывается работать, если на разделе меньше 60 GiB свободно
   или `out/` занят более 15 GiB.

### disk — этап 2в, готов к включению после согласования

```
ffmpeg --> /srv/video-studio-data (ext4 40 GiB) --> готовый файл сразу на месте
```

Предел задаёт файловая система: при переполнении запись останавливается с
`ENOSPC`. Ограничение действует на сумму файлов, а не на один файл. Подробный
разбор схем, риски и точные команды — `../План-хранения-2026-11-15.md`.

## Ограда

Перед каждым запуском ffmpeg проверяется:

| Режим | Что проверяется |
|---|---|
| `tmpfs` | `/out` — `tmpfs`, размер не больше 1 GiB, запись возможна |
| `disk` | `/out` — не `tmpfs` и не слой контейнера; размер совпадает с маркером `/storage/.storage-size-gib` (±5%), запись возможна; `/scratch` на той же файловой системе |

Отказ всегда с кодом 78, ffmpeg не запускается. Проверены отказы: bind общего
раздела (935 GiB) без маркера и с поддельным маркером «40 GiB», `tmpfs`, ext4
размером 1 GiB, read-only каталог, отсутствие хранилища.

**Честная граница.** В режиме `tmpfs` жёсткие пределы — это `tmpfs` и
`RLIMIT_FSIZE`, а проверки объёма `out/` — контроль, не квота. В режиме `disk`
жёсткий предел даёт файловая система 40 GiB. Квоты на Docker-образы и build cache
нет: они лежат на общем разделе, и `check-docker-space.sh` только измеряет их
перед установкой HyperFrames.

## Запуск

```bash
cd /home/igor/video-studio

# режим tmpfs, как сейчас
./scripts/run-render.sh -i /work/in.mp4 -c:v libx264 -preset veryfast /out/out.mp4

# режим disk, после создания хранилища
MODE=disk ./scripts/run-render.sh -i /work/in.mp4 -c:v libx264 -preset veryfast /out/out.mp4
```

Входные файлы: `work/` в режиме `tmpfs`, `/srv/video-studio-data/in` в режиме
`disk`. Оба монтируются только на чтение.

Проверки:

```bash
./scripts/verify.sh                      # режим tmpfs
./scripts/verify-storage.sh              # хранилище, без заполнения
./scripts/verify-storage.sh --fill       # плюс проверка отказа при переполнении
./scripts/check-docker-space.sh          # бюджет перед HyperFrames
./host/check-storage.sh                  # состояние хранилища
```

## Порядок включения режима disk

Выполняется только после отдельного разрешения на привилегированные операции.

```bash
cd /home/igor/video-studio

sudo ./host/setup-storage.sh                    # 1. примерка, ничего не меняет
sudo ./host/setup-storage.sh --apply            # 2. создать и смонтировать
./scripts/verify-storage.sh                     # 3. базовые проверки
./scripts/verify-storage.sh --fill              # 4. доказать предел
docker compose -f compose.disk.yaml up -d studio-disk   # 5. включить сервис
MODE=disk ./scripts/run-render.sh ... /out/probe.mp4     # 6. пробный запуск
```

Откат: `docker compose -f compose.disk.yaml down`, затем
`sudo ./host/remove-storage.sh --apply`. Режим `tmpfs` при этом остаётся рабочим
всё время — `compose.yaml` не меняется.

## Остановка и полное удаление

```bash
cd /home/igor/video-studio
docker compose down                 # остановить среду tmpfs, образ остаётся
docker compose -f compose.disk.yaml down   # остановить сервис disk
docker compose down --rmi local     # остановить и удалить образ
rm -rf /home/igor/video-studio      # удалить каталог
```

`docker compose down` не трогает образы, тома и сети других проектов. Общий
`docker prune` не нужен и не применяется.

## Технические особенности

- База `debian:bookworm-slim`, а не Alpine: бинарники BtbN собраны под glibc.
- `tmpfs /out` монтируется с режимом `1777`: этот runtime не принимает `uid`/`gid`
  в опциях tmpfs. В контейнере один пользователь.
- В режиме `tmpfs` контейнер живёт постоянно (`sleep infinity`), потому что tmpfs
  существует только пока контейнер запущен. В режиме `disk` это не нужно, но
  схема запуска та же.
- `docker cp` не видит `tmpfs` внутри контейнера, поэтому в режиме `tmpfs`
  публикация идёт потоком `tar`.
- `stat -f -c %T` не различает ext2/3/4 и печатает `ext2/ext3`, поэтому ограда в
  режиме `disk` проверяет отказ от `tmpfs`/`overlay` и размер, а не имя типа.
- Лицензия GPL-2.0-or-later: вариант `gpl` включает `libx264` и `libx265`.
  Использование локальное; распространение образа требует соблюдения GPL.
