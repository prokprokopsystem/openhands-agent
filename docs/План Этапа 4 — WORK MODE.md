# Этап 4 — WORK MODE: сухой план

**Дата:** 26 июля 2026  
**Основание:** DEC-021, DEC-022, docs/Архитектура.md, исследование API Agent Canvas 1.6.1  
**Статус:** READ-ONLY анализ. Никаких изменений не выполнено.

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

### 1.2. Инструменты (16 шт.)

| Категория | Инструменты |
|-----------|-------------|
| Файлы | `file_editor`, `edit`, `read_file`, `write_file`, `list_directory`, `glob`, `grep`, `planning_file_editor` |
| Терминал | `terminal` |
| Задачи | `task_tool_set`, `task`, `task_tracker` |
| Workflow | `workflow_tool_set`, `workflow` |
| Браузер | `browser_tool_set` |
| UI | `canvas_ui_control` |

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

### 1.4. Egress-политика (текущая)

```
ESTABLISHED,RELATED → RETURN
БЛОК: 127.0.0.0/8, 169.254.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 95.217.239.148
DNS (53) → RETURN
HTTP/HTTPS (80, 443) → RETURN
ВСЁ ОСТАЛЬНОЕ → DROP
```

**Для WORK MODE потребуется:** открыть egress к конкретным внутренним сервисам (API Notion через интернет уже доступен по 443; n8n на VPS — нужен доступ к `95.217.239.148:443`; Nextcloud — нужен доступ к `cloud.prokop-agent.duckdns.org:443`).

### 1.5. Механизмы интеграции

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
| `terminal` | ✅ Разрешён | `/projects` (work-workspace) | `rm -rf`, `sudo`, systemctl, docker, перезапись конфигов | Доступ к `/srv/amnesia*`, `/srv/nextcloud`, `~/.ssh` | `history \| grep` после теста | Флаг `tools` в профиле |
| `read_file` | ✅ Разрешён | `/projects`, `/docs` | — | `/srv/amnesia*`, `/srv/nextcloud/data`, `/home/openhands/.openhands` | `cat /projects/test.txt` | Ограничение volumes |
| `write_file` | ✅ Разрешён | `/projects` | Массовая запись, перезапись конфигов | `/srv/*` вне `/projects` | Создатьファイル → проверить | Ограничение volumes |
| `file_editor` | ✅ Разрешён | `/projects` | Правка конфигов | То же | `edit` тест | Флаг `tools` |
| `list_directory` | ✅ Разрешён | `/projects` | — | `/srv/*`, `/home` | `ls` тест | Флаг `tools` |
| `glob`, `grep` | ✅ Разрешён | `/projects` | — | Поиск секретов | Поиск тест | Флаг `tools` |
| `task`, `task_tracker` | ✅ Разрешён | — | — | — | Создать задачу | Флаг `tools` |
| `browser_tool_set` | ⚠️ По умолчанию выкл | Интернет (80/443) | Включение | Внутренние адреса | N/A | Флаг `tools` |
| `workflow_tool_set` | ⚠️ По умолчанию выкл | — | Включение, массовое удаление | Production workflows без backup | N/A | Флаг `tools` |
| `planning_file_editor` | ✅ Разрешён | `/projects` | — | — | Создать план | Флаг `tools` |
| `canvas_ui_control` | ✅ Разрешён | — | — | — | UI-тест | Флаг `tools` |

### 2.2. Интеграции (будущие — НЕ в этом этапе)

| Интеграция | Механизм | Требует |
|-----------|----------|---------|
| **n8n** | MCP-сервер или HTTP-эндпоинт | API-ключ n8n (read-only), egress к VPS:443 |
| **GitHub** | MCP-сервер или SSH-ключ | Deploy key (read-only), egress к github.com:443 |
| **Notion** | MCP-сервер или HTTP-эндпоинт | Notion API-токен, egress к api.notion.com:443 |
| **Nextcloud** | HTTP-эндпоинт (WebDAV/API) | Пароль приложения, egress к cloud.prokop-agent.duckdns.org:443 |
| **AMNESIA** | MCP-сервер (существующий `amnesia-bridge`) | Auth0-токен, egress к amnesia.prokop-agent.duckdns.org:443 |

### 2.3. Правила подтверждения (через system_message_suffix)

Обычные действия в `/projects` — без подтверждения.  
**Обязательное подтверждение (через `ask_user` или `confirmation_policy`):**

- `rm -rf`, удаление каталогов
- `docker`, `systemctl`, `sudo`
- Изменение конфигов в `config/`
- Операции с `main`-веткой Git
- Массовое удаление/перезапись
- Работа с production-данными

**Полностью запрещено (через prompt):**

- Выход за пределы `/projects`
- Чтение `/srv/openhands-agent/config/secrets/`
- Изменение firewall, compose, systemd
- Доступ к WireGuard, VPS-конфигурации

---

## 3. Сухой план реализации

### Этап 4A — Профиль WORK MODE (без интеграций)

**Изменяемые позиции (3 Git-файла + 1 каталог на хосте):**

| # | Файл/Каталог | Действие | Конкретное изменение |
|---|-------------|----------|---------------------|
| 1 | `config/agent-profiles/work.json` | **Создать** | Новый agent-профиль с `tools: [...]` — список из 11 инструментов |
| 2 | `config/settings.json` | **Изменить** | 4 параметра: `active_agent_profile_id` → work, `agent_context.system_message_suffix` (правила WORK MODE), `agent_context.load_memory` (по решению), `conversation_settings.confirmation_mode` (оставить `false`) |
| 3 | `deployment/compose.yaml` | **Изменить** | Заменить volume: `test-workspace:/projects` → `work-workspace:/projects` |
| 4 | `/srv/openhands-agent/work-workspace/` | **Создать** | Пустой каталог на хосте, `chown 10001:10001`, `chmod 700` |

Итого: **3 файла в Git + 1 каталог на mini-server.**

**НЕ изменять:** systemd, firewall, egress-правила, LLM-профиль, Docker-образ, порты, WireGuard.

### Этап 4B — Egress для интеграций (отдельно)

**Только после подтверждения Игоря.**

| Файл | Изменение |
|------|-----------|
| `deployment/network/apply-egress-rules.sh` | Добавить RETURN для `95.217.239.148:443` (n8n) |
| `deployment/network/apply-egress-rules.sh` | Добавить RETURN для `api.notion.com:443` |

### Этап 4C — Подключение интеграций (отдельно, по одной)

Для каждой: MCP-сервер или API-эндпоинт → тест → docs → commit.

### Порядок действий (4A):

1. **Backup**: скопировать `settings.json`, `agent-profiles/default.json`
2. **Создать** `agent-profiles/work.json` с ограниченным списком инструментов
3. **Обновить** `settings.json`: `active_agent_profile_id`, `system_message_suffix`, `load_memory`
4. **Создать** `work-workspace` каталог на хосте
5. **Обновить** `compose.yaml`: заменить `test-workspace:/projects` на `work-workspace:/projects`
6. **Перезапустить** `systemctl restart openhands-agent`
7. **Postcheck**: профиль active, инструменты ограничены, workspace доступен
8. **Тест**: создать файл, прочитать, удалить — проверить правила подтверждения
9. **Персистентность**: restart → профиль и workspace сохранились
10. **Docs + commit**

---

## 4. Решения, которые должен принять Игорь

| # | Вопрос | Варианты | Последствия |
|---|--------|----------|-------------|
| 1 | **Создавать новый agent-профиль `work` или переименовать `default`?** | А) Новый `work` → default остаётся как TEST MODE. Б) Переименовать default → work | А) Два профиля — можно переключаться. Меньше риск сломать. Б) Один профиль — проще, но теряется TEST MODE |
| 2 | **Какие инструменты оставить?** Точный список: `terminal`, `read_file`, `write_file`, `file_editor`, `edit`, `list_directory`, `glob`, `grep`, `task`, `task_tracker`, `planning_file_editor`, `canvas_ui_control` (12). Без: `browser_tool_set`, `workflow_tool_set`, `workflow` | Утвердить 12 / Изменить список | 12 инструментов = полный файловый доступ + задачи. Без browser и workflow — изоляция от web и автоматизации |
| 3 | **`load_memory` — включить память агента?** | А) `true`. Б) `false` | А) Агент запоминает контекст между сессиями. Б) Каждый чат с нуля — безопаснее |
| 4 | **Создавать `work-workspace` или переиспользовать `test-workspace`?** | А) Новый `/srv/openhands-agent/work-workspace`. Б) Очистить test-workspace | А) Чистое разделение TEST/WORK. Б) Меньше каталогов |
| 5 | **Монтировать `docs/` как read-only в контейнер?** | А) Да — `docs:/docs:ro`. Б) Нет | А) Агент читает документацию проекта. Б) Вся документация — вне контейнера, агент её не видит |
| 6 | **Egress: сейчас (вместе с 4A) или отдельно (4B)?** | А) Только 4A. Б) 4A+4B вместе | А) Безопасный первый шаг. Б) Быстрее, но больше изменений за раз |
| 7 | **Язык `system_message_suffix`?** | А) Русский. Б) Английский | А) Понятно Игорю при аудите. Б) Родной язык DeepSeek — возможно, точнее соблюдается |
| 8 | **`verification.critic_enabled`?** | А) `true` — двойная проверка опасных действий. Б) `false` — только prompt | А) Дополнительный рубеж. Замедляет каждое действие. Б) Быстрее, но защита только текстовая |

### 4.1. Предварительная позиция Игоря (зафиксирована 26.07.2026)

| # | Решение | Позиция |
|---|--------|---------|
| 1 | Новый профиль | ✅ Создать `work`, default сохранить |
| 2 | Инструменты | ⚠️ Утвердить после просмотра точных названий (см. список из 12 выше) |
| 3 | `load_memory` | ✅ Включить |
| 4 | Workspace | ✅ Отдельный `work-workspace` |
| 5 | `docs/` mount | ❌ Не давать доступ к секретам, системным каталогам и другим проектам |
| 6 | Egress | ⚠️ Не открывать широко — только необходимый контроль (4B отдельно) |
| 7 | Язык prompt | ❓ Не указано |
| 8 | `critic_enabled` | ⚠️ Опасные действия нельзя считать надёжно защищёнными одним prompt — принципиальное ограничение Canvas |
| — | `confirmation_mode` | ✅ Оставить включённым (`true`) — вопреки предложению плана |

**Нерешённые вопросы для уточнения:**
- Язык `system_message_suffix` (русский / английский)?
- `confirmation_mode: true` — означает, что каждое действие потребует подтверждения. Это замедлит работу. Альтернатива: `confirmation_mode: false` + строгие правила в prompt + `security_analyzer: "llm"`?
- Доступ к `docs/`: если не монтировать — агент не видит документацию. Если монтировать read-only — агент читает, но не пишет. Какой вариант?
- Принципиальное ограничение Canvas (п. 8): нужен ли внешний шлюз разрешений (например, прокси-слой перед контейнером) или принимаем риск текстовой защиты?

---

## 5. Что НЕ делать в этом этапе

- ❌ Не подключать GitHub, VPS, SSH, n8n, Nextcloud, Notion, AMNESIA
- ❌ Не менять Docker, Compose (кроме volume), systemd, firewall, WireGuard, порты
- ❌ Не менять LLM-профиль (deepseek-chat остаётся)
- ❌ Не менять архитектуру (Agent Canvas, supervisor, контейнер — неизменны)
- ❌ Не создавать новые Docker-контейнеры, сервисы, сети
- ❌ Не устанавливать MCP-серверы, плагины, навыки
- ❌ Не читать API-ключи, пароли, токены, `.env`
