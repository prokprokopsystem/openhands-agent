# Дизайн первого изолированного теста

**Статус:** техническая подготовка исправлена; реальный запуск ещё не выполнялся.

## Выбранная сборка

- Agent Canvas `1.6.1`.
- Образ закреплён полным linux/amd64 digest: `sha256:fc24163754bee2ab0115b117d57512cc01b4d99770e7ac17c3607e76290deeb6`.
- WebUI: `/canvas`, порт `8000`.
- Внутренние компоненты: Agent Server `18000`, Automation `18001`.
- Docker socket не используется.

## Контур

```text
ПК/телефон → WireGuard → 10.77.0.2:8000/canvas
                              ↓
                       openhands-agent
                       10.89.0.2/28
```

Публичного домена нет. На порту 8000 отдельного экрана ввода `LOCAL_BACKEND_API_KEY` нет: entrypoint передаёт session key frontend автоматически. Единственный внешний рубеж теста — WireGuard. Публичный доступ запрещён до отдельного этапа авторизации.

## Данные и права

| Хост | Контейнер | Права/назначение |
|---|---|---|
| `/srv/openhands-agent/config` | `/home/openhands/.openhands` | 700; настройки и LLM-секреты |
| `/srv/openhands-agent/test-workspace` | `/projects` | 700; пустой тестовый workspace |
| `/srv/openhands-agent/secrets` | env file | 700 |
| `secrets/.env` | `LOCAL_BACKEND_API_KEY` | 600 |
| `/srv/openhands-agent/logs` | служебное | 700 |

LLM-провайдер, модель и API-ключ настраиваются только через `Settings → LLM`.

## Жизненный цикл

Единственный владелец — `openhands-agent.service`.

- Compose: `restart: "no"`.
- Systemd ждёт Docker, `wg-quick@wg0` и адрес `10.77.0.2` не более 60 секунд.
- Затем выполняет `docker compose config`, `docker compose create`, применяет firewall и запускает `docker compose up` в foreground.
- При падении systemd перезапускает сервис.
- При остановке сначала останавливается Compose, затем удаляются правила OpenHands.

Прямой `docker compose up -d` не является штатным способом запуска.

## Сетевая политика

Отдельные цепочки `OPENHANDS-EGRESS` и `OPENHANDS-INPUT` действуют только для `10.89.0.0/28`.

Разрешены DNS и внешний HTTP/HTTPS. Запрещены mini-server, Docker gateway, AMNESIA, Nextcloud, WireGuard/LAN, чужие Docker-сети, VPS, все прочие публичные порты и IPv6.

После запуска проверка выполняется с хоста скриптом `deployment/network/check-egress.sh`, который запускает тесты внутри контейнера через `docker exec`.

## Health

Docker healthcheck проверяет:

- HTTP `/canvas`;
- TCP listener Agent Server `127.0.0.1:18000`;
- TCP listener Automation `127.0.0.1:18001`.

`status.sh` дополнительно показывает systemd, Compose, Docker health, HTTP-код, внутренние listeners, CPU/RAM, ошибки, firewall и WireGuard.

## Первый тест

Только после отдельного разрешения:

1. разместить репозиторий в `/srv/openhands-agent`;
2. выполнить `prepare.sh`;
3. создать `secrets/.env`;
4. установить и включить systemd unit;
5. запустить через `start.sh`;
6. выполнить `status.sh` и `check-egress.sh`;
7. открыть WebUI через WireGuard;
8. настроить одну LLM через WebUI;
9. проверить файл, остановку задачи, перезапуск и сохранение состояния.

GitHub, SSH, AMNESIA, Nextcloud, n8n и Notion в первом тесте не подключаются.

## Откат

`stop.sh` сохраняет данные. `purge-test.sh` без параметра только показывает план удаления. Необратимое удаление требует `--confirm-destroy-test-data` и удаляет только systemd unit, firewall-цепочки, контейнер/сеть и каталог тестового проекта.

Каноническая инструкция: `deployment/README.md`.
