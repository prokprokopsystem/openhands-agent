# Этап 5C — Telegram-бот: аудит и сухой план

**Дата:** 26 июля 2026  
**Статус:** ✅ РЕАЛИЗОВАН. Gateway запущен, работает, проверен пользователем.
**Примечание:** данный документ — исходный план этапа. Актуальное состояние и детали реализации — в `docs/Состояние.md`.

---

**Результат:** Текстовый Telegram-бот @ProkopAsystentBot подключён к Agent Canvas через host-side gateway. Только user_id Игоря, только private-чат, только текст. Проверено: сообщение из Telegram → ответ агента, общая сессия с браузером.

---

## 1. Аудит существующего бота

### 1.1. Папка с ключами

| Параметр | Значение |
|----------|---------|
| Путь | `/workspace/ключи токены и другая жопа/` |
| Владелец | `hermes:hermes` |
| Файл бота | `token телеграм for bot Prokop Asystentnewbot .txt` (46 байт, 644) |

### 1.2. Данные бота (getMe)

| Параметр | Значение |
|----------|---------|
| Username | **@ProkopAsystentBot** |
| Name | Prokop Asystent/newbot |
| Bot ID | 7694171024 |
| Can join groups | True |

### 1.3. Используется ли бот сейчас?

| Проверка | Результат |
|----------|-----------|
| systemd-служба с ботом | ❌ Не найдена |
| Docker-контейнер | ❌ Не найден |
| Процесс long-polling | ❌ Не найден |
| n8n workflow/webhook | ❌ Не проверялся (бот не на VPS) |

**Вывод:** бот @ProkopAsystentBot свободен, не используется.

### 1.4. Telegram ID Игоря

**Не найден** ни в папке ключей, ни в конфигурации проекта. Потребуется получить после отправки первого сообщения боту.

---

## 2. Архитектура gateway

### 2.1. Схема

```
Telegram API (облако)
    ↕ long polling (getUpdates, timeout=30s)
openhands-tg-gateway (host-side Python-скрипт, systemd-служба)
    ├─ Токен: /srv/openhands-agent/secrets/telegram_bot_token (root:root, 600)
    ├─ Фильтр: только chat_id Игоря
    ├─ Текст → Agent Canvas API (POST /api/conversations/{id}/ask_agent)
    └─ Ответ → sendMessage обратно
    ↕ HTTP (локально, без авторизации между gateway и Canvas)
Agent Canvas (контейнер openhands-agent, 10.77.0.2:8000/18000)
```

### 2.2. Canvas API

| Параметр | Значение |
|----------|---------|
| Адрес | `http://10.77.0.2:18000` |
| Авторизация | `LOCAL_BACKEND_API_KEY` (из `/srv/openhands-agent/secrets/.env`) |
| Создание диалога | `POST /api/conversations` → `{"workspace": "/projects"}` → `conversation_id` |
| Запрос агенту | `POST /api/conversations/{id}/ask_agent` → `{"question": "текст"}` |
| Получение ответа | Синхронный ответ в теле запроса (ждёт до таймаута) |
| Продолжение диалога | Тот же `conversation_id` + повторный `ask_agent` |

### 2.3. Жизненный цикл диалога

- Каждый Telegram-чат Игоря → одна `conversation_id` в Canvas
- `conversation_id` хранится в памяти gateway (словарь `{chat_id: conv_id}`)
- При рестарте gateway: новый `chat_id` создаёт новый диалог
- Можно добавить хранение `conversation_id` в файл для персистентности (будущее улучшение)

### 2.4. Ограничения

| Параметр | Реализация |
|----------|-----------|
| Только chat_id Игоря | `if chat_id != ALLOWED_ID: sendMessage("Access denied")` |
| Группы запрещены | `if chat_type != "private": ignore` |
| Только текст | `if not message.text: sendMessage("Text only")` |
| Защита от повторов | `update_id` отслеживается, дубли игнорируются |
| Таймаут Canvas | 60 секунд на ответ агента |
| Длинные ответы | Разбиение по 4096 символов (лимит Telegram) |
| Canvas недоступен | `sendMessage("Agent is unavailable, try later")` |

---

## 3. Реализация

### 3.1. Файлы

| Файл | Назначение |
|------|-----------|
| `/srv/openhands-agent/secrets/telegram_bot_token` | Токен бота (root:root, 600) — **пока не создавать** |
| `/usr/local/bin/openhands-tg-gateway.py` | Gateway-скрипт (Python) |
| `/etc/systemd/system/openhands-tg-gateway.service` | systemd-служба |

### 3.2. systemd-служба

```
[Unit]
Description=OpenHands Telegram Gateway
After=network.target openhands-agent.service
Wants=openhands-agent.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/openhands-tg-gateway.py
Restart=always
RestartSec=10
User=root
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
```

### 3.3. Журнал

- `systemd journal` (`journalctl -u openhands-tg-gateway`)
- **НЕ содержит:** токен, текст переписки, chat_id (только факт запроса/ответа)
- Формат: `[timestamp] message from USER_ID: processing... OK (N chars)`

### 3.4. Отключение

```bash
sudo systemctl stop openhands-tg-gateway
# Canvas продолжает работать независимо
```

### 3.5. Зависимости

Только стандартная библиотека Python 3: `json`, `urllib`, `time`, `os`. Никаких внешних пакетов (не `telethon`, не `pyrogram`).

---

## 4. План реализации

1. **Получить Telegram ID Игоря** — отправить одно сообщение боту, прочитать `getUpdates`
2. **Скопировать токен** → `/srv/openhands-agent/secrets/telegram_bot_token` (root:root, 600)
3. **Создать gateway-скрипт** `/usr/local/bin/openhands-tg-gateway.py`
4. **Создать и запустить systemd-службу**
5. **Тест:** сообщение → ответ агента
6. **Docs + commit**

### 3.6. Порядок после утверждения

| Шаг | Действие |
|-----|----------|
| 1 | Игорь отправляет одно сообщение боту @ProkopAsystentBot |
| 2 | Hermes читает `getUpdates`, извлекает `chat.id`, записывает в конфиг |
| 3 | Hermes копирует токен в `/srv/openhands-agent/secrets/telegram_bot_token` |
| 4 | Hermes создаёт gateway-скрипт |
| 5 | Hermes создаёт и запускает systemd-службу |
| 6 | Игорь отправляет тестовое сообщение → получает ответ агента |
| 7 | Hermes проверяет отказ для другого пользователя |
| 8 | Docs + commit |

---

## 5. Судьба папки ключей

Исходная папка `/workspace/ключи токены и другая жопа/` **остаётся** резервным хранилищем всех credentials. После копирования токена в `/srv/openhands-agent/secrets/` она не удаляется. Оба места попадают в ежедневный backup проекта (5A).

---

## 6. Что НЕ делать

- ❌ Не создавать нового бота — использовать @ProkopAsystentBot
- ❌ Не использовать Telethon/Pyrogram/MTProto (только Bot API)
- ❌ Не открывать webhook, HTTPS, домен
- ❌ Не обрабатывать голос, фото, файлы (только текст)
- ❌ Не разрешать группы и inline-режим
- ❌ Не копировать токен до APPLY
