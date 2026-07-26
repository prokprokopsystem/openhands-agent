# Этап 5B — Healthcheck и мониторинг: аудит и сухой план

**Дата:** 26 июля 2026  
**Статус:** READ-ONLY аудит. Никаких изменений не выполнено.

---

## 1. Аудит текущего состояния

### 1.1. Docker healthcheck

| Параметр | Значение |
|----------|---------|
| Test | `curl /canvas:8000` + TCP 18000 + TCP 18001 |
| Interval | 30s |
| Timeout | 10s |
| Retries | 3 (unhealthy после 3×30s = 90s) |
| Start period | 90s |
| Текущий статус | ✅ healthy (failing streak: 0) |

**Логика:** контейнер `unhealthy` после 3 последовательных провалов → watchdog останавливает контейнер → `exit 1` → systemd `Restart=on-failure` → перезапуск всего сервиса.

### 1.2. Политика перезапуска

| Уровень | Механизм | Поведение |
|--------|----------|-----------|
| Docker | `restart: "no"` | Docker не перезапускает |
| Watchdog | `health-watchdog.sh` | 3×unhealthy → `docker stop` → `exit 1` |
| Systemd | `Restart=on-failure` | Перезапускает весь юнит (ExecStartPre → ExecStart) |
| After reboot | `enabled` | Автозапуск при загрузке |

**Полный цикл восстановления:** сбой → 3×unhealthy (90s) → watchdog kill → systemd restart → prepare → validate → compose up → 90s start_period → healthy.

### 1.3. Systemd-юниты проекта

| Юнит | Тип | Статус |
|------|-----|--------|
| `openhands-agent.service` | service | ✅ active (running), enabled |
| `openhands-backup.timer` | timer | ✅ active (waiting), enabled |

### 1.4. HTTP-эндпоинты для проверки

| Эндпоинт | Порт | Код | Назначение |
|----------|------|-----|-----------|
| `/canvas` | 8000 | 200 | WebUI (основной пользовательский) |
| `/health` | 18000 | 200 | Agent Server health |
| `/ready` | 18000 | 200 | Agent Server readiness |
| `/alive` | 18000 | 200 | Agent Server liveness |

Все 4 эндпоинта доступны внутри контейнера и отвечают 200.

### 1.5. Журналы

| Журнал | Механизм | Ротация | Размер |
|--------|----------|---------|--------|
| Docker logs | `json-file` | `max-size=10m`, `max-file=3` | ~30 MB макс |
| systemd journal | `journald` | Автоматически | 105.9 MB (весь сервер) |

### 1.6. Поведение после перезагрузки сервера

- `openhands-agent.service`: `enabled` → автозапуск ✅
- `openhands-backup.timer`: `enabled` → автозапуск ✅
- WireGuard проверяется в `ExecStartPre` (таймаут 60s)
- Полное время восстановления после reboot: ~2 мин (WG + 90s start_period)

---

## 2. Оценка текущего покрытия

| Сценарий | Покрыт? | Механизм |
|----------|---------|----------|
| Контейнер упал (exit ≠ 0) | ✅ | systemd `Restart=on-failure` |
| Контейнер завис (не отвечает) | ✅ | Docker healthcheck → watchdog → systemd |
| Agent Server упал | ✅ | TCP 18000 в healthcheck |
| Automation backend упал | ✅ | TCP 18001 в healthcheck |
| WebUI не грузится | ✅ | `/canvas` HTTP 200 в healthcheck |
| LLM API недоступен | ❌ | Не проверяется (контейнер healthy, но модель не работает) |
| Диск заполнен | ❌ | Не проверяется |
| Внешний диск отключён | ⚠️ | Backup проверяет, но агент — нет |
| Уведомление при сбое | ❌ | Нет (будет в 5C — Telegram) |

**Вывод:** ядро мониторинга уже реализовано и работает. Текущий healthcheck + watchdog + systemd покрывают критические сбои контейнера. Не хватает: оповещения и мониторинга хостовых ресурсов.

---

## 3. Минимальная схема (без новых сервисов)

### 3.1. Что уже есть и остаётся без изменений

| Компонент | Статус |
|-----------|--------|
| Docker healthcheck | ✅ Работает |
| `health-watchdog.sh` | ✅ Работает |
| `systemd Restart=on-failure` | ✅ Работает |
| `enabled` after reboot | ✅ Работает |

### 3.2. Что добавить: host-side проверка

**Простой скрипт** `/usr/local/bin/openhands-health-check.sh`:

```bash
#!/usr/bin/bash
# Host-side health check — вызывается вручную или из cron/systemd timer.
# Проверяет: служба active, контейнер healthy, Canvas HTTP 200.
# Пишет результат в journald (через systemd-cat или logger).
set -euo pipefail

# 1. Systemd unit active?
if ! systemctl is-active -q openhands-agent.service; then
    echo "openhands-agent: INACTIVE" | systemd-cat -t openhands-health -p err
    exit 1
fi

# 2. Container healthy?
STATUS=$(docker inspect -f '{{.State.Health.Status}}' openhands-agent 2>/dev/null)
if [ "$STATUS" != "healthy" ]; then
    echo "openhands-agent container: $STATUS" | systemd-cat -t openhands-health -p err
    exit 1
fi

# 3. Canvas responds?
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://10.77.0.2:8000/canvas 2>/dev/null)
if [ "$HTTP" != "200" ]; then
    echo "openhands-agent canvas: HTTP $HTTP" | systemd-cat -t openhands-health -p err
    exit 1
fi

echo "openhands-agent: OK (active, healthy, canvas 200)" | systemd-cat -t openhands-health -p info
```

**Запуск:** вручную `openhands-health-check.sh` или через systemd timer раз в 5 минут.

### 3.3. Критерии healthy/unhealthy

| Состояние | Критерий |
|-----------|---------|
| **healthy** | systemd active + контейнер healthy + canvas 200 |
| **degraded** | systemd active, но контейнер starting/unhealthy (временное) |
| **unhealthy** | systemd inactive ИЛИ контейнер unhealthy > 3 проверок подряд |

### 3.4. Интервалы

| Проверка | Интервал | Кто выполняет |
|----------|----------|---------------|
| Docker healthcheck | 30s | Docker daemon |
| Watchdog | 10s | `health-watchdog.sh` в контейнере |
| Host-side проверка | 5 мин | systemd timer (опционально) |
| Уведомление | — | Пока не подключается (ждёт 5C) |

### 3.5. Откат

Удалить timer и скрипт:
```bash
sudo systemctl disable --now openhands-health-check.timer 2>/dev/null
sudo rm /usr/local/bin/openhands-health-check.sh
```

---

## 4. Что НЕ делать

- ❌ Не добавлять новые сервисы мониторинга (Prometheus, Grafana, etc.)
- ❌ Не подключать Telegram, email, webhook-уведомления (будет в 5C)
- ❌ Не менять существующий healthcheck, watchdog, systemd unit
- ❌ Не добавлять проверки диска/памяти (можно позже)

---

## 5. Рекомендация

**Минимальная реализация:** только host-side скрипт проверки + вывод в journald. Всё остальное уже работает. Этап 5B можно считать завершённым после добавления скрипта — остальное покрыто существующими механизмами.

**Изменения:** 1 новый файл (`/usr/local/bin/openhands-health-check.sh`), без изменений в существующих конфигах.
