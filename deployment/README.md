# OpenHands Agent Canvas — первый тестовый запуск

## Архитектура

```
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
- **WebUI:** `http://10.77.0.2:8000/canvas` (base path: `/canvas`)
- **Пользователь в контейнере:** `openhands` (uid 1000)
- **Docker socket:** не используется (песочница = сам контейнер)
- **Постоянные данные:** `/home/openhands/.openhands` (настройки) + `/projects` (workspace)

## Первый запуск

```bash
# 1. Создать каталоги на mini-server
ssh mini-server
sudo mkdir -p /srv/openhands-agent/{config,workspace,secrets,logs}
sudo chown -R igor:igor /srv/openhands-agent

# 2. Сгенерировать API-ключ
openssl rand -base64 32 > /tmp/api-key.txt

# 3. Создать .env с ключом
cat > /srv/openhands-agent/secrets/.env << 'ENVEOF'
LOCAL_BACKEND_API_KEY=<ключ из /tmp/api-key.txt>
ENVEOF
chmod 600 /srv/openhands-agent/secrets/.env

# 4. Скопировать compose.yaml на сервер
scp deployment/compose.yaml mini-server:/srv/openhands-agent/

# 5. Запустить
cd /srv/openhands-agent
docker compose up -d
```

## Проверка

```bash
# Health
curl -s http://10.77.0.2:8000/ | head -1

# Логи
docker compose -f /srv/openhands-agent/compose.yaml logs -f --tail 50

# Статус
docker compose -f /srv/openhands-agent/compose.yaml ps
```

## Доступ

Открыть в браузере (при подключённом WireGuard):
```
http://10.77.0.2:8000/canvas
```

Ввести `LOCAL_BACKEND_API_KEY` на экране входа.

## Настройка LLM

После входа: **Settings → LLM** → выбрать провайдера (OpenAI/Anthropic/OpenRouter), ввести API-ключ и модель. Настройки сохраняются в `/home/openhands/.openhands`.

## Остановка

```bash
cd /srv/openhands-agent
docker compose down
```

## Полное удаление тестового запуска

```bash
cd /srv/openhands-agent
docker compose down --volumes
sudo rm -rf /srv/openhands-agent
```

Состояние (config, workspace) будет потеряно! Для сохранения — не удалять `/srv/openhands-agent/config/`.

## Ограничения безопасности

- Контейнер НЕ имеет доступа к `/var/run/docker.sock`
- Рабочий каталог — только `/srv/openhands-agent/workspace/`
- Нет bind-mount каталогов AMNESIA (`/srv/prokop/projects/amnesia/`)
- Нет bind-mount каталогов Nextcloud (`/srv/nextcloud/`)
- Сеть изолирована: `openhands-net` (bridge), не подключена к `nextcloud-aio` или `bridge_default`
- `no-new-privileges:true`

## Ресурсы

- CPU: максимум 2 ядра, резерв 1 ядро
- RAM: максимум 4 GB, резерв 1 GB
- Логи: ротация 10 MB × 3 файла

## Автозапуск

`restart: unless-stopped` в compose.yaml. После перезагрузки mini-server контейнер поднимется автоматически (Docker daemon enabled).
