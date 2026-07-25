# OpenHands — исследование платформы

**Дата:** 25 июля 2026  
**Исполнитель:** Hermes (read-only, без установки)  
**Проект:** OpenHands Agent — Этап 1 (исследование)  
**Источники:**  
- https://github.com/OpenHands/OpenHands  
- https://github.com/OpenHands/agent-canvas  
- https://github.com/OpenHands/software-agent-sdk  
- https://docs.openhands.dev  

---

## 1. Что такое OpenHands сегодня

**Важно:** OpenHands прошёл реструктуризацию. Монолитный `OpenHands/OpenHands` разделён на модули:

| Репозиторий | Назначение |
|---|---|
| `OpenHands/agent-canvas` | Веб-интерфейс (Agent Canvas) — фронтенд, CLI-лаунчер, npm-пакет, Docker-образ |
| `OpenHands/software-agent-sdk` | Agent Server — REST API для запуска агентов, sandbox, workspace |
| `OpenHands/automation` | Automation Server — запуск агентов по расписанию или webhook |
| `OpenHands/OpenHands` | Архивный репозиторий, код перенесён, осталась документация |

**Официальный продукт:** `@openhands/agent-canvas` (npm) / `ghcr.io/openhands/agent-canvas` (Docker).

---

## 2. Актуальная версия

| Параметр | Значение |
|---|---|
| Стабильная версия | **v1.6.1** |
| Дата выпуска | 24 июля 2026 |
| Статус | Beta |
| NPM | `@openhands/agent-canvas@1.6.1` |
| Docker | `ghcr.io/openhands/agent-canvas:1.6.1` |
| Звёзд | 82.1k |
| Коммитов | 7 081 |

---

## 3. Способы установки

### Способ A — npm (без sandbox)

```bash
npm install -g @openhands/agent-canvas
agent-canvas
```

- Агент запускается прямо на хосте
- Полный доступ к файловой системе
- ⚠️ **Не рекомендуется** для продакшена без жёсткого firewall

### Способ B — Docker (с sandbox)

```bash
docker run -it --rm \
  -p 8000:8000 \
  -v "$HOME/.openhands:/home/openhands/.openhands" \
  -v "${PROJECTS_PATH}:/projects" \
  ghcr.io/openhands/agent-canvas:1.6.1
```

- Агент внутри контейнера
- Доступ только к примонтированным каталогам
- UI на `http://localhost:8000/canvas`
- ✅ **Рекомендуется** для безопасной установки

### Способ C — из исходников

```bash
git clone https://github.com/OpenHands/agent-canvas.git
cd agent-canvas
npm install
npm run dev
```

---

## 4. Требования к ресурсам

| Ресурс | Минимум | Рекомендовано | На mini-server |
|---|---|---|---|
| CPU | 2 vCPU | 2 vCPU | ✅ 4 ядра (i5-7500) |
| RAM | 4 GB | 4 GB | ✅ 12 GB available |
| Диск | — | Зависит от проектов | ✅ 873 GB свободно |
| Docker | Engine | Engine | ✅ 29.1.3 |
| ОС | Linux/macOS | Ubuntu 24.04 | ✅ Ubuntu 26.04 |
| Node.js | 22.12.x+ | 22.x | ⚠️ Нужна установка |
| uv | требуется | последняя | ⚠️ Нужна установка |

**Вывод:** mini-server значительно превышает минимальные требования.

---

## 5. Архитектура

```
Пользователь (браузер)
        │ HTTPS :443
        ▼
nginx (TLS termination)
        │
        ▼ 127.0.0.1:8000
Ingress proxy
  ├─ /*           → Static frontend (:3001)
  ├─ /api/*       → Agent Server    (:18000)
  └─ /api/automation/* → Automation (:18001)
```

**Внутренние порты:**

| Компонент | Порт | Интерфейс |
|---|---|---|
| Ingress (точка входа) | 8000 | 127.0.0.1 |
| Static frontend | 3001 | внутренний |
| Agent Server | 18000 | внутренний |
| Automation backend | 18001 | внутренний |

**Для нашего случая:** все порты остаются на `127.0.0.1`, публичный доступ — через Nginx на VPS как reverse proxy через WireGuard к `10.77.0.2:8000`. Порты 3001/18000/18001 не публикуются.

---

## 6. WebUI (Agent Canvas)

| Возможность | Поддержка |
|---|---|
| Чат (текст) | ✅ Да |
| Вставка из буфера | ✅ Да |
| Загрузка файлов | ✅ Да |
| Изображения/фото | ✅ Да (просмотр в чате) |
| Голосовой ввод | ❌ **Нет** (не встроен) |
| Мобильный доступ | ✅ Да (через браузер, адаптивный UI) |
| История чатов | ✅ Да |
| Переключение backend | ✅ Да (несколько Agent Server) |
| Остановка задачи | ✅ Да |
| Терминал в UI | ✅ Да |
| Браузер в UI | ✅ Да |
| Файловый менеджер | ✅ Да |
| Настройки LLM | ✅ Да (в UI) |

**Мобильный телефон:** WebUI адаптивный, работает через браузер. Специального мобильного приложения нет — только веб.

**Голос:** отсутствует. Потребуется отдельный компонент (например, браузерный Web Speech API или внешний STT/TTS).

---

## 7. Поддерживаемые модели и провайдеры

OpenHands Agent Canvas поддерживает любые модели через конфигурацию LLM-профилей в UI:

- OpenAI
- Anthropic
- Google (Gemini)
- Любой OpenAI-compatible провайдер (OpenRouter, Groq, Together, etc.)
- Локальные модели (через Ollama, vLLM)

**Ключи API:** передаются через UI в настройках (Settings → LLM). Хранятся в конфигурации backend (не в фронтенде). Никакой жёсткой привязки к одному провайдеру нет.

---

## 8. Постоянное хранение

### При Docker-установке:

| Данные | Путь на хосте | В контейнере |
|---|---|---|
| Конфигурация OpenHands | `$HOME/.openhands` | `/home/openhands/.openhands` |
| Проекты (workspace) | `PROJECTS_PATH` | `/projects` |

### Что нужно сохранять:

- `.openhands/` — настройки, LLM-профили, ключи API, история
- `/projects/` — рабочие файлы агента
- Конфигурация systemd (если используется)
- nginx config
- Сертификаты (на VPS)

**Для нашего mini-server:**

| Назначение | Путь |
|---|---|
| Конфигурация агента | `/srv/openhands-agent/config/` → `:/home/openhands/.openhands` |
| Workspace проектов | `/srv/openhands-agent/workspace/` → `:/projects` |
| Логи | `/srv/openhands-agent/logs/` |
| Секреты | `/srv/openhands-agent/secrets/` (mode 700) |
| Backups | `/mnt/amnesia-backup/openhands-agent/` |

---

## 9. Безопасность и sandbox

### Docker-режим (рекомендованный):

- Агент внутри контейнера, изолирован
- Доступ только к явно примонтированным томам
- Нет доступа к Docker socket
- Read-only root filesystem (настраивается)

### Режим без Docker (опасный):

- Агент на хосте, полный доступ к ФС
- Требует жёсткого firewall
- ⚠️ Не рекомендуется

### Авторизация:

- **API Key:** `LOCAL_BACKEND_API_KEY` (256-bit, `openssl rand -base64 32`)
- **Public mode:** ключ НЕ вшит в фронтенд, пользователь вводит при первом входе
- Все `/api/*` запросы требуют заголовок `X-Session-API-Key`
- **Нет** OAuth, **нет** multi-user, **нет** ролей — только один ключ

### Docker socket:

- В Docker-режиме агент НЕ имеет доступа к `/var/run/docker.sock`
- Sandbox реализован самим Docker-контейнером, а не агентом
- **Риск:** при пробросе docker socket агент получает root-доступ к хосту
- **Решение:** НЕ монтировать docker socket в контейнер агента

---

## 10. Автозапуск и восстановление

### Systemd unit (рекомендовано):

```ini
[Unit]
Description=OpenHands Agent Canvas
After=network.target docker.service
Requires=docker.service

[Service]
Environment=LOCAL_BACKEND_API_KEY=<ключ>
ExecStart=docker run --rm \
  -p 127.0.0.1:8000:8000 \
  -v /srv/openhands-agent/config:/home/openhands/.openhands \
  -v /srv/openhands-agent/workspace:/projects \
  ghcr.io/openhands/agent-canvas:1.6.1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- `Restart=on-failure` — восстановление после сбоя
- `Requires=docker.service` — ждать Docker
- После перезагрузки mini-server поднимется автоматически

---

## 11. Ограничения OpenHands

| Ограничение | Влияние |
|---|---|
| **Нет голосового ввода** | Нужен внешний STT или Web Speech API |
| **Нет multi-user** | Один API-ключ на всех. Нет ролей. |
| **Нет OAuth/SSO** | Только API Key, нет интеграции с Google/GitHub |
| **API-key — единая точка отказа** | Утечка ключа = полный доступ |
| **Нет встроенного backup** | Нужно настраивать отдельно |
| **Бета-статус** | Возможны breaking changes между версиями |
| **Docker sandbox ≠ полная изоляция** | Агент видит примонтированные тома |
| **Нет лимитов по CPU/RAM** | Агент может потребить все ресурсы |
| **Нет file wall** | Агент видит все файлы в `/projects` |

---

## 12. Оценка пригодности штатного WebUI

### Под наши требования:

| Требование | Статус | Примечание |
|---|---|---|
| Доступ с ПК и телефона | ✅ | Через браузер |
| Текстовый чат | ✅ | Полноценный |
| Вставка из буфера | ✅ | |
| Файлы и фото | ✅ | Загрузка и просмотр |
| Голосовой ввод | ❌ | Отсутствует |
| История | ✅ | Сохраняется |
| Остановка задачи | ✅ | Кнопка в UI |
| Понятные ошибки | ✅ | В чате |
| Подтверждение действий | ⚠️ | Частично (зависит от режима) |

**Вывод:** штатный WebUI Agent Canvas **подходит** как основа. Главный пробел — отсутствие голосового ввода. Это можно закрыть отдельным компонентом (браузерный Web Speech API или внешний STT-сервис) на более позднем этапе.

**Отдельный frontend (Open WebUI) НЕ требуется.** Agent Canvas даёт всё необходимое, кроме голоса.

---

## 13. Рекомендуемая версия для первого теста

| Параметр | Значение |
|---|---|
| Версия | **v1.6.1** |
| Образ | `ghcr.io/openhands/agent-canvas:1.6.1` |
| Способ | Docker (без docker socket) |
| Порты | Ingress: `127.0.0.1:8000` (или `10.77.0.2:8000` через WG) |
| Volumes | `/srv/openhands-agent/config:/home/openhands/.openhands` + `/srv/openhands-agent/workspace:/projects` |
| Авторизация | `LOCAL_BACKEND_API_KEY` + public mode |
| Systemd | Unit с `Restart=on-failure`, `Requires=docker.service` |

---

## 14. Открытые вопросы (требуют решения на следующих этапах)

- [ ] Какой домен использовать: `agent.prokop-agent.duckdns.org`?
- [ ] На каком интерфейсе публиковать порт 8000: `127.0.0.1` или `10.77.0.2`?
- [ ] Нужна ли установка Node.js и uv на хост (для npm-режима) или достаточно Docker?
- [ ] Какую модель LLM использовать как основную?
- [ ] Голос: браузерный Web Speech API или внешний STT/TTS?
- [ ] Нужен ли Automation Server (сразу или позже)?
- [ ] Какой `PROJECTS_PATH` — один каталог на все проекты или отдельные?

---

## Рекомендуемый следующий один этап

**Этап 2: тестовый запуск OpenHands Agent Canvas v1.6.1 в Docker на mini-server.**

- Создать каталоги `/srv/openhands-agent/config/` и `/srv/openhands-agent/workspace/`
- Сгенерировать `LOCAL_BACKEND_API_KEY`
- Запустить контейнер вручную (без systemd) на `10.77.0.2:8000`
- Проверить UI с компьютера и телефона (текст, файлы, фото)
- Убедиться, что агент не затрагивает Nextcloud, AMNESIA и другие сервисы
- НЕ настраивать nginx, домен и HTTPS на этом этапе
- Остановить контейнер после проверки

Результат: подтверждение, что WebUI работает, и замер фактического потребления CPU/RAM.

---

*Конец исследования. 25 июля 2026.*
