# OpenHands Agent Canvas — первый тестовый запуск

## Архитектура

```text
Пользователь (браузер)
  └─ WireGuard (10.77.0.x)
       └─ mini-server (10.77.0.2:8000)
            └─ openhands-agent (Docker-контейнер)
                 ├─ Agent Canvas UI (:8000)
                 ├─ Agent Server (:18000, internal)
                 └─ Automation backend (:18001, internal)
```

- **Образ:** `ghcr.io/openhands/agent-canvas:1.6.1`
- **Порт:** `10.77.0.2:8000` — только через WireGuard
- **WebUI:** `http://10.77.0.2:8000/canvas`
- **Пользователь контейнера:** `openhands` (uid 1000)
- **Docker socket:** не используется
- **Постоянные данные на хосте:** `/srv/openhands-agent/config/` и `/srv/openhands-agent/workspace/`

## Первый запуск

Команды выполняются только после отдельного разрешения на реальный запуск.

```bash
# 1. Подключиться к mini-server
ssh mini-server

# 2. Создать отдельные каталоги проекта
sudo mkdir -p /srv/openhands-agent/{config,workspace,secrets,logs}
sudo chown -R igor:igor /srv/openhands-agent
chmod 700 /srv/openhands-agent/secrets

# 3. Создать ключ входа в Agent Canvas без временного файла
umask 077
printf 'LOCAL_BACKEND_API_KEY=%s\n' "$(openssl rand -base64 32)" \
  > /srv/openhands-agent/secrets/.env
chmod 600 /srv/openhands-agent/secrets/.env

# 4. Поместить compose.yaml в каталог проекта
# Выполняется с компьютера, где клонирован репозиторий:
# scp deployment/compose.yaml mini-server:/srv/openhands-agent/compose.yaml

# 5. Проверить конфигурацию без запуска
cd /srv/openhands-agent
docker compose config

# 6. Первый запуск
# docker compose up -d
```

## Проверка после запуска

```bash
# Проверка WebUI
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  http://10.77.0.2:8000/canvas

# Статус контейнера
docker compose -f /srv/openhands-agent/compose.yaml ps

# Последние логи
docker compose -f /srv/openhands-agent/compose.yaml logs --tail 100
```

## Доступ

При подключённом WireGuard открыть:

```text
http://10.77.0.2:8000/canvas
```

Для входа используется значение `LOCAL_BACKEND_API_KEY` из:

```text
/srv/openhands-agent/secrets/.env
```

Сам ключ в GitHub не сохраняется.

## Настройка LLM

После первого входа открыть **Settings → LLM**, выбрать провайдера, модель и ввести API-ключ. Переменные `LLM_API_KEY`, `LLM_MODEL` и `LLM_BASE_URL` в `.env` для этого образа не используются.

Настройки должны сохраняться через bind mount:

```text
/srv/openhands-agent/config/ → /home/openhands/.openhands
```

## Остановка без удаления данных

```bash
cd /srv/openhands-agent
docker compose down
```

Каталоги `config/`, `workspace/` и `secrets/` остаются на хосте.

## Удаление только контейнера и сети теста

```bash
cd /srv/openhands-agent
docker compose down --remove-orphans
```

## Полное удаление данных теста

Выполнять только после отдельного подтверждения, поскольку команда необратимо удаляет настройки, ключ входа и workspace:

```bash
cd /srv/openhands-agent
docker compose down --remove-orphans
sudo rm -rf /srv/openhands-agent
```

## Ограничения безопасности

- контейнер не получает `/var/run/docker.sock`;
- рабочий каталог ограничен `/srv/openhands-agent/workspace/`;
- каталоги AMNESIA и Nextcloud не монтируются;
- используется отдельная сеть `openhands-net`;
- порт публикуется только на адресе WireGuard `10.77.0.2`;
- включён `no-new-privileges:true`;
- настоящие ключи не хранятся в GitHub.

## Ресурсы

- CPU: максимум 2 ядра;
- RAM: максимум 4 GB;
- журнал Docker: 10 MB × 3 файла.

## Автозапуск

`restart: unless-stopped` поднимает контейнер после перезапуска Docker и mini-server, кроме случая, когда контейнер был намеренно остановлен вручную.
