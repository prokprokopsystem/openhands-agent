# Дизайн первого тестового запуска

**Дата:** 25 июля 2026  
**Проект:** OpenHands Agent — Этап 2  

---

## 1. Выбранные версии

| Компонент | Версия | Источник |
|---|---|---|
| Agent Canvas (GUI + Server) | **v1.6.1** | `ghcr.io/openhands/agent-canvas:1.6.1` |
| Дата релиза | 24 июля 2026 | https://github.com/OpenHands/agent-canvas/releases/tag/v1.6.1 |
| Документация | https://docs.openhands.dev | Официальные доки |

**Примечание:** старый «Local GUI V1» помечен как deprecated. Agent Canvas — официальный наследник.

---

## 2. Архитектура тестового запуска

```
Пользователь (браузер, ПК/телефон)
  │
  └─ WireGuard (10.77.0.x)
       │
       ▼
mini-server 10.77.0.2:8000
  │
  └─ openhands-agent (Docker-контейнер)
       ├─ Agent Canvas UI / Ingress :8000
       ├─ Agent Server :18000 (internal)
       └─ Automation backend :18001 (internal)
```

- Только WireGuard, без публичного домена
- HTTPS не требуется (трафик внутри WG-туннеля)
- Отдельная Docker-сеть `openhands-net`

---

## 3. Назначение Docker socket

**Docker socket НЕ используется.** Agent Canvas v1.6.1 не требует `/var/run/docker.sock`.

В старом Local GUI V1 docker.sock был нужен для создания sandbox-контейнеров. В Agent Canvas песочницей является сам контейнер — агент работает внутри него, изолирован Docker'ом. Это безопаснее.

---

## 4. Постоянные каталоги

| Каталог на хосте | В контейнере | Назначение |
|---|---|---|
| `/srv/openhands-agent/config/` | `/home/openhands/.openhands` | Настройки, история, LLM-профили |
| `/srv/openhands-agent/workspace/` | `/projects` | Рабочие файлы проектов |
| `/srv/openhands-agent/secrets/` | только env_file | API-ключи (mode 600) |
| `/srv/openhands-agent/logs/` | — | Логи контейнера (json-file driver) |

---

## 5. Хранение API-ключа

- Файл: `/srv/openhands-agent/secrets/.env`
- Права: `igor:igor`, mode `600`
- В Git: только `.env.example` (без настоящих ключей)
- Переменная: `LOCAL_BACKEND_API_KEY`
- Генерация: `openssl rand -base64 32`

---

## 6. Порт

| Параметр | Значение |
|---|---|
| Порт | **8000** |
| Интерфейс | **10.77.0.2** (только WireGuard) |
| Доступ | `http://10.77.0.2:8000/canvas` |
| Публичный | Нет (не exposed на 0.0.0.0) |

Порт 8000 проверен как свободный на mini-server (в аудите заняты: 22, 3478, 8080, 11000, 8090).

---

## 7. Ограничения ресурсов

| Ресурс | Лимит | Резерв |
|---|---|---|
| CPU | 2 ядра | 1 ядро |
| RAM | 4 GB | 1 GB |

---

## 8. Изоляция от существующих сервисов

- **Docker-сеть:** отдельная `openhands-net` (bridge), не подключена к `nextcloud-aio`, `bridge_default`
- **Bind mounts:** только `/srv/openhands-agent/` — нет доступа к `/srv/nextcloud/`, `/srv/prokop/projects/amnesia/`, `/mnt/amnesia-backup/`
- **Docker socket:** не монтируется
- **Безопасность:** `no-new-privileges:true`

---

## 9. Автозапуск

- Compose: `restart: unless-stopped`
- Docker daemon: `enabled` (systemd)
- После перезагрузки mini-server контейнер поднимется автоматически

---

## 10. Порядок первого запуска

1. Создать каталоги на mini-server:
   ```bash
   sudo mkdir -p /srv/openhands-agent/{config,workspace,secrets,logs}
   sudo chown -R igor:igor /srv/openhands-agent
   ```

2. Сгенерировать API-ключ:
   ```bash
   openssl rand -base64 32
   ```

3. Создать `/srv/openhands-agent/secrets/.env` с `LOCAL_BACKEND_API_KEY` и `LLM_API_KEY`

4. Скопировать `compose.yaml` на mini-server

5. Запустить:
   ```bash
   cd /srv/openhands-agent && docker compose up -d
   ```

6. Открыть `http://10.77.0.2:8000/canvas`, ввести API-ключ

---

## 11. Проверка

- `docker compose ps` — контейнер Up
- `curl -s -o /dev/null -w "%{http_code}" http://10.77.0.2:8000/` → HTTP 200
- Открыть в браузере → экран ввода API-ключа

---

## 12. Остановка

```bash
cd /srv/openhands-agent && docker compose down
```
Состояние сохраняется в `config/` и `workspace/`.

---

## 13. Полный откат

```bash
cd /srv/openhands-agent
docker compose down --volumes
sudo rm -rf /srv/openhands-agent
```
⚠️ Удаляет всё, включая историю и workspace.

---

## 14. Модели — варианты конфигурации

### Вариант 1: OpenAI

```env
LLM_API_KEY=sk-proj-...
LLM_MODEL=gpt-4o
LLM_BASE_URL=https://api.openai.com/v1
```

### Вариант 2: Anthropic

```env
LLM_API_KEY=sk-ant-...
LLM_MODEL=claude-sonnet-4-20250514
LLM_BASE_URL=https://api.anthropic.com/v1
```

### Вариант 3: OpenRouter

```env
LLM_API_KEY=sk-or-...
LLM_MODEL=anthropic/claude-sonnet-4
LLM_BASE_URL=https://openrouter.ai/api/v1
```

Пользователь предоставляет: название ключа, точную модель, base URL.

---

## 15. Нерешённые вопросы

- [ ] Какую модель выбрать (OpenAI / Anthropic / OpenRouter)?
- [ ] Нужен ли Automation Server на первом этапе?
- [ ] Голосовой ввод — браузерный Web Speech API или позже?
- [ ] Нужен ли домен и HTTPS для телефона (сейчас только WG)?
- [ ] Какие проекты положить в workspace для первого теста?

---

## 16. Созданные файлы

| Файл | Назначение |
|---|---|
| `deployment/compose.yaml` | Docker Compose (v1.6.1, WG-only, no docker.sock) |
| `deployment/.env.example` | Шаблон переменных (3 варианта LLM) |
| `deployment/README.md` | Инструкция по запуску |
| `deployment/scripts/start.sh` | Запуск |
| `deployment/scripts/stop.sh` | Остановка |
| `deployment/scripts/status.sh` | Статус |
| `deployment/scripts/logs.sh` | Логи |

---

*Готово к тестовому запуску. 25 июля 2026.*
