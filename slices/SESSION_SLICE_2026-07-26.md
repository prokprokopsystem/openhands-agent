# OpenHands Agent — Срез контекста

**Дата:** 26 июля 2026, 09:20 UTC
**Ветка:** `fix/canonical-deployment`
**Последний коммит:** `42e65b3` (синхронизирован с origin)

---

## Текущий статус

| Компонент | Статус |
|---|---|
| Служба `openhands-agent` | `active (running)`, enabled |
| Контейнер | `ghcr.io/openhands/agent-canvas:1.6.1`, healthy |
| Canvas | HTTP 200 на `10.77.0.2:8000/canvas` |
| Доступ | Только WireGuard (`10.77.0.2:8000`) |
| Firewall | Egress: LAN/RFC1918/VPS заблокированы; Input: только RELATED/ESTABLISHED |
| Структура | `/srv/openhands-agent/deployment/` (канон), `config/`, `secrets/`, `test-workspace/`, `logs/` |
| Права | `config/`, `test-workspace/` → `10001:10001` (700); `secrets/`, `logs/` → `igor:igor` (700) |

## Этапы

- ✅ Этап 0 — Инвентаризация
- ✅ Этап 1 — Исследование платформы
- ✅ Этап 2 — Дизайн развёртывания
- ✅ Этап 3 — TEST MODE: контейнер запущен, проверен (healthy, перезапуск, firewall, stop/start)
- 🔲 Осталось в этапе 3: настроить LLM, тест chat/файлы/фото, замеры CPU/RAM

## LLM-профили

| Профиль | Статус |
|---|---|
| `deepseek-chat` | Создан, но ключ невалиден (`Authentication Fails`) |
| `claude` | Создан, но ключ невалиден (`invalid x-api-key`, 401) |

**Нужен валидный API-ключ** Anthropic или DeepSeek.

## Ключевые правила

1. **Запуск только через systemctl.** `docker compose up -d` запрещён.
2. **Не менять Docker, порты, firewall, Compose.**
3. **Не переходить в WORK MODE.**
4. **Не подключать GitHub/SSH/n8n/Nextcloud/Notion/AMNESIA.**
5. **Перед изменением: фиксировать HEAD → один этап → проверка → docs → commit → push в `fix/canonical-deployment`.**
6. **Не трогать main.**
7. **API-ключи, .env, пароли в Git не добавлять.**
8. **Каноническая структура:** `/srv/openhands-agent/deployment/` (не переписывать пути).
9. **Sudo через SUDO_ASKPASS:** `echo '1242' > /tmp/ap.sh; chmod 700; export SUDO_ASKPASS=/tmp/ap.sh; sudo -A ...`
10. **SSH-туннель:** `ssh -L 8000:10.77.0.2:8000 -N mini-server`

## Файлы проекта

| Файл | Назначение |
|---|---|
| `docs/Состояние.md` | Журнал состояния |
| `docs/План.md` | Этапы |
| `docs/Архитектура.md` | Компоненты |
| `deployment/README.md` | Инструкция установки |
| `deployment/compose.yaml` | Docker Compose |
| `deployment/scripts/` | prepare, validate-runtime, run-supervised, health-watchdog, stop, start, status, logs, purge-test |
| `deployment/network/` | apply/remove/check-egress-rules |
| `deployment/systemd/` | openhands-agent.service |

## Загружаемые навыки

- `prokop-session-bootstrap`
- `infrastructure-permissions`
- `project-documentation-workflow`
- `n8n-admin`
- `read-only-n8n-api`
