# Agent Canvas 1.6.1 — безопасный первый тест

Это единственная инструкция запуска. До отдельной команды ничего на mini-server не устанавливать и не запускать.

## Контур теста

- WebUI: `http://10.77.0.2:8000/canvas`, только через WireGuard.
- Публичного домена и второго рубежа авторизации пока нет.
- `LOCAL_BACKEND_API_KEY` автоматически передаётся frontend внутри приватного WG-контура; отдельного экрана ввода ключа на порту 8000 нет.
- Модель и её API-ключ вводятся после запуска через `Settings → LLM`.
- Монтируется только пустой `/srv/openhands-agent/test-workspace`.
- GitHub, SSH, AMNESIA, Nextcloud, n8n и Notion не подключаются.
- Docker socket не монтируется.

## Владелец жизненного цикла

Единственный владелец запуска — `openhands-agent.service`. В Compose установлено `restart: "no"`. Прямой `docker compose up -d` запрещён.

Systemd ждёт Docker и `wg-quick@wg0`, создаёт контейнер без запуска, устанавливает egress-правила и затем держит `docker compose up` в foreground. При остановке удаляются только правила OpenHands.

## Файлы на mini-server

Репозиторий должен находиться в `/srv/openhands-agent`, чтобы существовали:

- `/srv/openhands-agent/deployment/compose.yaml`;
- `/srv/openhands-agent/deployment/scripts/`;
- `/srv/openhands-agent/deployment/network/`;
- `/srv/openhands-agent/deployment/systemd/openhands-agent.service`.

Постоянные каталоги:

- `config` — mode 700, настройки и LLM-секреты;
- `secrets` — mode 700;
- `secrets/.env` — mode 600;
- `test-workspace` — mode 700;
- `logs` — mode 700.

## Подготовка перед первым запуском

После отдельного разрешения:

```bash
sudo /srv/openhands-agent/deployment/scripts/prepare.sh
sudo cp /srv/openhands-agent/deployment/systemd/openhands-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable openhands-agent.service
```

Создать `/srv/openhands-agent/secrets/.env` с одной строкой и правами 600:

```env
LOCAL_BACKEND_API_KEY=<случайный непустой ключ>
```

Настоящие LLM-ключи в `.env` не помещаются.

## Запуск и остановка

```bash
/srv/openhands-agent/deployment/scripts/start.sh
/srv/openhands-agent/deployment/scripts/status.sh
/srv/openhands-agent/deployment/network/check-egress.sh
/srv/openhands-agent/deployment/scripts/stop.sh
```

## Что проверяем в первом тесте

- WebUI с ПК и телефона через WireGuard;
- Docker health: frontend и внутренние порты Agent Server/Automation;
- настройку одной LLM через WebUI;
- загрузку тестового файла;
- остановку задачи;
- перезапуск сервиса и сохранение состояния;
- CPU/RAM;
- невозможность доступа к AMNESIA, Nextcloud, mini-server SSH, LAN, VPS и произвольным публичным портам.

## Удаление теста

Обычная остановка данные не удаляет. Полное удаление сначала работает в preview-режиме:

```bash
/srv/openhands-agent/deployment/scripts/purge-test.sh
```

Необратимое удаление возможно только явно:

```bash
/srv/openhands-agent/deployment/scripts/purge-test.sh --confirm-destroy-test-data
```
