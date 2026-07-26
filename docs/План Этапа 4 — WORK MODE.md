# Этап 4 — WORK MODE: сухой план

**Дата:** 26 июля 2026  
**Основание:** DEC-021, DEC-022, docs/Архитектура.md, исследование API Agent Canvas 1.6.1  
**Статус:** READ-ONLY анализ. Решения Игоря зафиксированы. Никаких изменений не выполнено.

---

## 1. Что обнаружено в Agent Canvas 1.6.1

### 1.1. Где хранится профиль разрешений

| Хранилище | Путь | Содержит |
|-----------|------|----------|
| Agent-профиль | `config/agent-profiles/default.json` | `agent`, `tools`, `llm_profile_ref`, `agent_context`, `condenser`, `verification` |
| LLM-профили | `config/profiles/*.json` | `model`, `api_key`, `base_url`, параметры |
| Settings | `config/settings.json` | `active_profile`, `active_agent_profile_id`, `conversation_settings`, `agent_settings` |
| Контекст агента | `agent_context` внутри settings/профиля | `skills[]`, `system_message_suffix`, `load_user_skills`, `load_memory`, `secrets` |
| Беседы | `config/agent-canvas/conversations/*/` | `base_state.json`, `events/`, `meta.json` |

**Вывод:** постоянный профиль разрешений — это agent-профиль (`agent-profiles/*.json`) + `agent_context` внутри `settings.json`. Оба переживают restart (bind mount).

### 1.2. Инструменты — 16 шт., дублей не выявлено

| Категория | Инструменты |
|-----------|-------------|
| Файлы | `file_editor`, `edit`, `read_file`, `write_file`, `list_directory`, `glob`, `grep`, `planning_file_editor` |
| Терминал | `terminal` |
| Задачи | `task_tool_set` (включает `task` + `task_tracker`) |
| Workflow | `workflow_tool_set` (включает `workflow`) |
| Браузер | `browser_tool_set` |
| UI | `canvas_ui_control` |

**Проверка дублей:** `file_editor` и `edit` — разные инструменты (file_editor = полноценный редактор, edit = targeted search-and-replace). `task_tool_set` — это bundle, содержащий `task` и `task_tracker`; при включении `task_tool_set` отдельные `task`/`task_tracker` не нужны. `workflow_tool_set` — bundle, содержащий `workflow`.

**Для WORK MODE предложено 10 инструментов** (исключены: `browser_tool_set`, `workflow_tool_set`, `workflow`, `task`, `task_tracker`, `file_editor`, `planning_file_editor`):

| # | Инструмент | Обоснование |
|---|-----------|-------------|
| 1 | `terminal` | Основной рабочий инструмент |
| 2 | `read_file` | Чтение файлов |
| 3 | `write_file` | Запись файлов |
| 4 | `edit` | Прицельное редактирование (замена `file_editor`) |
| 5 | `list_directory` | Навигация по каталогам |
| 6 | `glob` | Поиск файлов по маске |
| 7 | `grep` | Поиск по содержимому |
| 8 | `task_tool_set` | Управление задачами (вместо отдельных `task` + `task_tracker`) |
| 9 | `planning_file_editor` | Редактирование планов |
| 10 | `canvas_ui_control` | Управление UI |

Все инструменты доступны когда `tools: null` (текущее состояние). Можно ограничить списком.

### 1.3. Модель разрешений

| Параметр | Текущее значение | Что делает |
|----------|-----------------|------------|
| `confirmation_mode` | `false` | Нет подтверждения действий |
| `security_analyzer` | `"llm"` | LLM анализирует безопасность |
| `tools` | `null` | Все инструменты доступны |
| `enable_sub_agents` | `false` | Субагенты запрещены |
| `verification.critic_enabled` | `false` | Критик выключен |

**Ограничения платформы:**
- Agent Canvas **не имеет** встроенного шлюза разрешений с детальными политиками (allow/deny по ресурсам). Есть только бинарные флаги: инструмент доступен/нет, confirmation_mode вкл/выкл.
- Тонкая настройка «подтверждать опасные действия» реализуется через **prompt** (system_message_suffix в agent_context) + `security_analyzer: "llm"`.
- Ограничение рабочей области — через `volumes` в compose (bind mount конкретных каталогов).

### 1.4. Текущие mount-точки

| Тип | Источник | Назначение | Права |
|-----|----------|-----------|-------|
| bind | `/srv/openhands-agent/config` | `/home/openhands/.openhands` | RW |
| bind | `/srv/openhands-agent/test-workspace` | `/projects` | RW |

Docker named volumes не используются для `/projects` или `/home/openhands/.openhands`. Оба — bind mount.

### 1.5. Egress-политика (текущая)

```
ESTABLISHED,RELATED → RETURN
БЛОК: 127.0.0.0/8, 169.254.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 95.217.239.148
DNS (53) → RETURN
HTTP/HTTPS (80, 443) → RETURN
ВСЁ ОСТАЛЬНОЕ → DROP
```

### 1.6. Файловая изоляция — проверка доступа UID 10001

**Проверялся доступ изнутри контейнера (UID 10001 = пользователь `openhands`):**

| Путь (внутри контейнера) | Доступ | Владелец | Права | Содержит секреты? |
|--------------------------|--------|----------|-------|-------------------|
| `/home/openhands/.openhands/profiles/deepseek-chat.json` | RW | 10001:10001 | 600 | ⚠️ API-ключ DeepSeek |
| `/home/openhands/.openhands/profiles/claude.json` | RW | 10001:10001 | 600 | ⚠️ API-ключ Claude |
| `/home/openhands/.openhands/settings.json` | RW | 10001:10001 | 600 | Нет |
| `/home/openhands/.openhands/agent-profiles/default.json` | RW | 10001:10001 | 600 | Нет |
| `/home/openhands/.openhands/agent-canvas/secret-key.txt` | RW | 10001:10001 | 600 | ⚠️ Внутренний ключ Canvas |
| `/home/openhands/.ssh` | ❌ Не существует | — | — | — |
| `/var/run/docker.sock` | ❌ Не существует | — | — | — |
| `/.dockerenv` | R | 0:0 | 755 | Нет |
| `.env` | ❌ Не существует | — | — | — |
| `secrets/` (каталог) | ❌ Не существует | — | — | — |

**Файлы секретов на хосте (НЕ видны контейнеру):**

| Путь на хосте | Владелец | Права | Виден UID 10001? |
|---------------|----------|-------|------------------|
| `/srv/openhands-agent/secrets/.env` | igor:igor | 600 | ❌ Нет — каталог `secrets/` не смонтирован в контейнер |

**Критическая находка:** `profiles/*.json` содержат API-ключи LLM и доступны UID 10001 на чтение и запись. Это архитектурное свойство Agent Canvas — LLM-ключи хранятся в JSON-профилях, доступных агенту. Файловая изоляция через `chmod` невозможна (сломает смену LLM через WebUI).

**Меры (без изменения архитектуры):**
- `profiles/*.json` — оставить как есть; агент по определению знает свой LLM-ключ
- `secrets/.env` — ❌ не смонтирован → агент не видит хостовые секреты ✅
- `docker.sock` — ❌ не смонтирован → изоляция от Docker ✅
- `.ssh` — ❌ не существует → нет доступа к SSH-ключам ✅
- Защита: prompt + `security_analyzer: "llm"` + `verification.critic_enabled: true`

### 1.7. Механизмы интеграции

| Механизм | Доступность | Для WORK MODE |
|----------|-------------|---------------|
| MCP-серверы | API есть (`/api/mcp/*`), не настроены | Можно подключить MCP-сервер для n8n/Notion/GitHub |
| Skills (навыки) | API есть (`/api/skills/*`), marketplace пуст | Можно загрузить кастомные навыки |
| Plugins (плагины) | API есть (`/api/plugins/*`), не установлены | Можно установить |
| System message suffix | `agent_context.system_message_suffix` | Инструкции с правилами WORK MODE |
| Secrets | `/api/settings/secrets` | Хранение токенов интеграций |

---

## 2. Проект профиля WORK MODE

### 2.1. Таблица инструментов и разрешений

| Инструмент | Разрешение | Каталоги/ресурсы | Подтверждение Игоря | Запрещено | Проверка | Откат |
|-----------|-----------|-----------------|--------------------|-----------|----------|-------|
| `terminal` | ✅ Разрешён | `/projects` (work-workspace) | `rm -rf`, `sudo`, systemctl, docker, перезапись конфигов | `/srv/amnesia*`, `/srv/nextcloud` | `history \| grep` после теста | Флаг `tools` в профиле |
| `read_file` | ✅ Разрешён | `/projects`, `/docs` | — | `/home/openhands/.openhands` | `cat /projects/test.txt` | Ограничение volumes |
| `write_file` | ✅ Разрешён | `/projects` | Массовая запись | `/srv/*` вне `/projects` | Создать файл → проверить | Ограничение volumes |
| `edit` | ✅ Разрешён | `/projects` | Правка конфигов | То же | `edit` тест | Флаг `tools` |
| `list_directory` | ✅ Разрешён | `/projects` | — | `/srv/*`, `/home` | `ls` тест | Флаг `tools` |
| `glob`, `grep` | ✅ Разрешён | `/projects` | — | Поиск секретов | Поиск тест | Флаг `tools` |
| `task_tool_set` | ✅ Разрешён | — | — | — | Создать задачу | Флаг `tools` |
| `planning_file_editor` | ✅ Разрешён | `/projects` | — | — | Создать план | Флаг `tools` |
| `canvas_ui_control` | ✅ Разрешён | — | — | — | UI-тест | Флаг `tools` |

**Исключены из WORK MODE:**
- `browser_tool_set` — веб-доступ (опасно)
- `workflow_tool_set`, `workflow` — автоматизация (не нужно на этом этапе)
- `file_editor` — заменён на `edit` + `write_file`
- `task`, `task_tracker` — заменены на `task_tool_set` (bundle)

**Итого: 10 инструментов.**

### 2.2. Правила подтверждения (через system_message_suffix + critic)

Обычные действия в `/projects` — без подтверждения.  
**Обязательное подтверждение (через `ask_user` или `confirmation_policy`):**

- `rm -rf`, удаление каталогов
- `docker`, `systemctl`, `sudo`
- Изменение конфигов в `config/`
- Операции с `main`-веткой Git
- Массовое удаление/перезапись
- Работа с production-данными

**Полностью запрещено:**

- Выход за пределы `/projects` и `/docs`
- Чтение `/home/openhands/.openhands/profiles/` (секреты LLM)
- Чтение `/home/openhands/.openhands/agent-canvas/secret-key.txt`
- Изменение firewall, compose, systemd
- Доступ к WireGuard, VPS-конфигурации

### 2.3. Интеграции (будущие — НЕ в этом этапе)

| Интеграция | Механизм | Требует |
|-----------|----------|---------|
| **n8n** | MCP-сервер или HTTP-эндпоинт | API-ключ n8n (read-only), egress к VPS:443 |
| **GitHub** | MCP-сервер или SSH-ключ | Deploy key (read-only), egress к github.com:443 |
| **Notion** | MCP-сервер или HTTP-эндпоинт | Notion API-токен, egress к api.notion.com:443 |
| **Nextcloud** | HTTP-эндпоинт (WebDAV/API) | Пароль приложения, egress к cloud:443 |
| **AMNESIA** | MCP-сервер (существующий `amnesia-bridge`) | Auth0-токен, egress к amnesia:443 |

---

## 3. Сухой план реализации

### Этап 4A — Профиль WORK MODE (без интеграций)

**Изменяемые позиции (4 Git-файла + 2 каталога на хосте):**

| # | Файл/Каталог | Действие | Конкретное изменение |
|---|-------------|----------|---------------------|
| 1 | `config/agent-profiles/work.json` | **Создать** | Новый agent-профиль с `tools: [terminal, read_file, write_file, edit, list_directory, glob, grep, task_tool_set, planning_file_editor, canvas_ui_control]` |
| 2 | `config/settings.json` | **Изменить** | 4 параметра: `active_agent_profile_id` → work, `agent_context.system_message_suffix` (правила WORK MODE на русском), `agent_context.load_memory: true`, `verification.critic_enabled: true` |
| 3 | `deployment/compose.yaml` | **Изменить** | 2 volume: заменить `test-workspace:/projects` → `work-workspace:/projects`; добавить `/srv/openhands-agent/docs:/docs:ro` |
| 4 | `deployment/scripts/prepare.sh` | **Изменить** | Добавить создание `work-workspace/` (10001:10001, 700) и `docs/` (igor:igor, 755) |
| 5 | `/srv/openhands-agent/work-workspace/` | **Создать** | Пустой каталог на хосте, `chown 10001:10001`, `chmod 700` |
| 6 | `/srv/openhands-agent/docs/` | **Создать** | Каталог на хосте, заполнить из репозитория (`docs/Состояние.md`, `docs/План.md`, `docs/Архитектура.md`, `docs/Решения.md`, `deployment/README.md`), `chmod 755` |

**Итого: 4 файла в Git + 2 каталога на mini-server.**

**НЕ изменять:** systemd, firewall, egress-правила, LLM-профиль, Docker-образ, порты, WireGuard.

### Этап 4B — Egress для интеграций (отдельно)

**Только после подтверждения Игоря.**

| Файл | Изменение |
|------|-----------|
| `deployment/network/apply-egress-rules.sh` | Добавить RETURN для конкретных адресов (по одному за интеграцию) |

### Порядок действий (4A):

1. **Backup**: `settings.json`, `agent-profiles/default.json`, `compose.yaml`, `prepare.sh`
2. **Создать** `work-workspace/` и `docs/` на mini-server, заполнить docs из репозитория
3. **Создать** `agent-profiles/work.json` — профиль с 10 инструментами
4. **Обновить** `settings.json`: `active_agent_profile_id`, `system_message_suffix` (русский), `load_memory: true`, `critic_enabled: true`. `confirmation_mode` — оставить `false`
5. **Обновить** `compose.yaml`: volumes
6. **Обновить** `prepare.sh`: создание новых каталогов
7. **Перезапустить** `systemctl restart openhands-agent`
8. **Проверка изоляции**: проверить, что агент НЕ читает `profiles/*.json`, `secret-key.txt`, не выходит за `/projects`
9. **Тест**: создать/прочитать/удалить файл, задача через task_tool_set, план через planning_file_editor
10. **Персистентность**: restart → профиль, workspace, docs сохранились
11. **Только после успешной проверки изоляции:** `confirmation_mode: false` (если изоляция подтверждена)
12. **Docs + commit**

---

## 4. Зафиксированные решения Игоря (26.07.2026)

| # | Решение | Статус | Детали |
|---|--------|--------|--------|
| 1 | Новый профиль `work` | ✅ Утверждено | `default` сохраняется как TEST MODE |
| 2 | Инструменты | ✅ Утверждено | 10 инструментов: `terminal`, `read_file`, `write_file`, `edit`, `list_directory`, `glob`, `grep`, `task_tool_set`, `planning_file_editor`, `canvas_ui_control` |
| 3 | Память агента | ✅ `load_memory: true` | Агент запоминает контекст между сессиями |
| 4 | Workspace | ✅ Отдельный `work-workspace` | `/srv/openhands-agent/work-workspace`, 10001:10001, 700 |
| 5 | Docs | ✅ Read-only bind mount | `/srv/openhands-agent/docs:/docs:ro` — агент читает документацию |
| 6 | Egress | ✅ Отдельно (4B) | Не открывать широко — только конкретные адреса |
| 7 | Язык prompt | ✅ Русский | `system_message_suffix` на русском |
| 8 | Критик | ✅ `critic_enabled: true` | Дополнительная проверка опасных действий |
| 9 | `confirmation_mode` | ⚠️ `false` после проверки | Сначала `false`, но только после успешной проверки файловой изоляции |
| 10 | Доступ к секретам | ✅ Запрещён | `secrets/` не монтирован, docker.sock не монтирован, `.ssh` не существует |
| 11 | Файловая изоляция | ⚠️ Принято ограничение | `profiles/*.json` видны агенту (архитектурное ограничение Canvas). Защита: prompt + critic |

---

## 5. Что НЕ делать в этом этапе

- ❌ Не подключать GitHub, VPS, SSH, n8n, Nextcloud, Notion, AMNESIA
- ❌ Не менять Docker, Compose (кроме volumes), systemd, firewall, WireGuard, порты
- ❌ Не менять LLM-профиль (deepseek-chat остаётся)
- ❌ Не менять архитектуру (Agent Canvas, supervisor, контейнер — неизменны)
- ❌ Не создавать новые Docker-контейнеры, сервисы, сети
- ❌ Не устанавливать MCP-серверы, плагины, навыки
- ❌ Не читать API-ключи, пароли, токены, `.env`
