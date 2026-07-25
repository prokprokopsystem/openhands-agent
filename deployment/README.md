# OpenHands Agent Canvas — развёртывание

**Единственная инструкция установки.** Другие документы — канонические решения и архитектура.

## Первая установка и изолированный тестовый запуск

Это включает: копирование на mini-server, подготовку каталогов, создание ключа, установку systemd unit, скачивание образа, запуск контейнера, настройку LLM через WebUI, тест в пустом test-workspace.

### 1. Подготовка

```bash
# Копировать файлы на mini-server
scp -r deployment/ mini-server:/srv/openhands-agent/

# Создать каталоги и права
sudo /usr/bin/bash /srv/openhands-agent/deployment/scripts/prepare.sh
```

### 2. Создание ключа

```bash
umask 077
printf 'LOCAL_BACKEND_API_KEY=%s\n' "$(openssl rand -base64 32 | tr -d '\n')" \
  > /srv/openhands-agent/secrets/.env
chmod 600 /srv/openhands-agent/secrets/.env
```

### 3. Установка systemd unit

```bash
sudo cp /srv/openhands-agent/deployment/systemd/openhands-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### 4. Первый запуск

```bash
sudo systemctl start openhands-agent.service
sudo systemctl status openhands-agent.service
```

### 5. Доступ

```
http://10.77.0.2:8000/canvas (только WireGuard)
```

### 6. Настройка LLM

Открыть WebUI → **Settings → LLM** → выбрать провайдера (OpenAI/Anthropic/OpenRouter), ввести API-ключ и модель.

### 7. Тест

Проверить: чат, файлы, фото, остановку задачи, перезапуск, потребление CPU/RAM, egress-изоляцию (через check-egress.sh).

### 8. Остановка

```bash
sudo systemctl stop openhands-agent.service
```

Данные в `config/` и `test-workspace/` сохраняются.

### 9. Полное удаление

```bash
# Preview
sudo /usr/bin/bash /srv/openhands-agent/deployment/scripts/purge-test.sh

# Удаление
sudo /usr/bin/bash /srv/openhands-agent/deployment/scripts/purge-test.sh --confirm-destroy-test-data
```

## Lifecycle

```
systemd openhands-agent.service
  ├─ ExecStartPre: prepare.sh
  ├─ ExecStartPre: validate-runtime.sh
  ├─ ExecStartPre: ожидание wg0 10.77.0.2
  ├─ ExecStartPre: docker compose config
  ├─ ExecStartPre: docker compose create
  ├─ ExecStartPre: apply-egress-rules.sh
  ├─ ExecStart: run-supervised.sh (compose up + watchdog)
  ├─ ExecStop: docker compose down
  └─ ExecStopPost: remove-egress-rules.sh
```

## Ключевые решения

- **Запуск:** только через systemd (`systemctl start/stop`). `docker compose up -d` запрещён.
- **Firewall:** контейнер стартует ТОЛЬКО после применения egress-правил.
- **Watchdog:** 3×unhealthy → перезапуск через systemd Restart=on-failure.
- **Healthcheck:** `/canvas` HTTP 200 + TCP-проверка портов 18000/18001. TCP = доступность порта, не функциональная readiness API.
- **LLM:** через WebUI, не через env.
- **Авторизация:** `LOCAL_BACKEND_API_KEY` передаётся frontend автоматически. Экрана ручного ввода нет. Защита — WireGuard.
- **Секреты:** только в `/srv/openhands-agent/secrets/.env` (mode 600). Не в Git.
