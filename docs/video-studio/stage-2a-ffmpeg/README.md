# Этап 2а — изолированная среда FFmpeg / ffprobe

Один сервис, один образ, без сети, без прав, с жёсткими лимитами. HyperFrames,
Chromium, Node и генераторы моделей сюда не входят.

## Состав

| Файл | Назначение |
|---|---|
| `Dockerfile` | Образ на `debian:bookworm-slim` (закреплённый digest) + сборка FFmpeg 8.0.1 от BtbN, проверка sha256 |
| `compose.yaml` | Изоляция, лимиты ресурсов, монтирования |
| `scripts/preflight.sh` | Проверка свободного места и объёма `out/` перед записью |
| `scripts/verify.sh` | Проверка конфигурации, лимитов и наличия кодеков |

Рабочий каталог на mini-server: `/home/igor/video-studio`
- `image/ffmpeg/Dockerfile` — отсюда собирается образ;
- `work/` — входные медиа, монтируется только для чтения;
- `out/` — результат, монтируется для записи, владелец `10001:10001`;
- `scripts/` — оба скрипта.

## Источник и версия

- FFmpeg 8.0.1 (`n8.0.1-66-g27b8d1a017`), сборка `linux64-gpl`.
- Источник: GitHub Releases репозитория `BtbN/FFmpeg-Builds`, тег
  `autobuild-2026-02-28-12-59`.
- sha256 архива: `26d2ecd0cefba99f9d1ea92252a3a4f743a58df4c1c3cf9f8bbaaa40b1fca5b0`,
  сверяется в процессе сборки. Значение совпадает с закреплённым в
  `heygen-com/hyperframes/Dockerfile.test`, то есть проверено двумя источниками.
- Лицензия: GPL-2.0-or-later (вариант `gpl` включает libx264 и libx265).
  Использование локальное, распространение образа требует соблюдения GPL.
- База `debian:bookworm-slim`, а не Alpine: бинарники BtbN собраны под glibc.

## Сборка

```bash
cd /home/igor/video-studio
docker compose build
```

Сеть нужна только на этом шаге: скачивается архив FFmpeg. В рантайме сеть
отключена (`network_mode: none`).

## Проверка

```bash
cd /home/igor/video-studio
./scripts/verify.sh
```

Скрипт печатает версии, проверяет наличие `libx264`, `aac`, `libmp3lame` и
фильтров `concat`, `xfade`, `fade`, `scale`, `overlay`, `amix`, `volume`,
`loudnorm`, `atempo`, `setpts`, `fps`, `crop`, `pad`. Ни одного файла он не создаёт.

Проверка ограничений в отдельном терминале во время работы контейнера:

```bash
docker inspect --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.PidsLimit}}' \
  "$(docker compose ps -q ffmpeg)"
```

## Использование (этап 2б, только после отдельного согласования)

```bash
./scripts/preflight.sh                  # обязательная проверка диска
docker compose run --rm ffmpeg -i /work/in.mp4 -c:v libx264 -c:a aac /out/result.mp4
```

Входные файлы кладутся в `work/`, результат появляется в `out/` на хосте.

## Границы защиты диска

| Механизм | Тип | Что ограничивает |
|---|---|---|
| `tmpfs /tmp` 1 GiB | жёсткий, ядро | временные файлы; при 2 GiB памяти реально доступно ≈1 GiB |
| `ulimits: fsize` 4 GiB | жёсткий, ядро | размер одного файла |
| `scripts/preflight.sh` | проверка перед запуском | свободное место ≥ 60 GiB, `out/` ≤ 15 GiB |

**Честно:** квоты на каталог `out/` на уровне файловой системы нет. Она требует
прав root на хосте (project quota ext4 или отдельный LV) и в эту работу не
входила. Поэтому «лимит 20 GB на вывод» не обеспечивается и не заявляется.
Ограничение `out/` контролируется скриптом перед запуском, а не ядром.

## Удаление только этой среды

```bash
cd /home/igor/video-studio
docker compose down --rmi local --volumes --remove-orphans
docker image rm video-studio/ffmpeg:8.0.1
rm -rf /home/igor/video-studio
```

Команды не затрагивают другие проекты: у Compose-проекта своё имя
`video-studio`, своих сетей и томов он не создаёт, `prune` не используется.

## Что запрещено на этом этапе

HyperFrames, Chromium, Node, Remotion, генераторы моделей, тестовые ролики,
нагрузочные рендеры, публикация портов, `privileged`, `docker.sock`,
`host network`, монтирование каталогов production.
