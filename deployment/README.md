# OpenHands Agent Canvas — развёртывание

## Архитектура запуска

```
systemd (openhands-agent.service)
  ├─ ExecStartPre: validate-runtime.sh (проверка .env, wg, docker, compose)
  └─ ExecStart: run-supervised.sh
       ├─ docker compose up (foreground)
       └─ health-watchdog.sh (3×unhealthy → перезапуск)
```

**Главный lifecycle:** systemd. `start.sh` — удобная оболочка для ручного теста.

## Первый запуск (только ручной тест)

```bash
# На mini-server:
sudo /usr/bin/bash deployment/scripts/prepare.sh

# Создать secrets/.env
openssl rand -base64 32 > /tmp/api-key.txt
cat > /srv/openhands-agent/secrets/.env << 'ENVEOF'
LOCAL_BACKEND_API_KEY=*** из /tmp/api-key.txt>
ENVEOF
chmod 600 /srv/openhands-agent/secrets/.env

# Ручной запуск (без systemd)
sudo /usr/bin/bash deployment/scripts/start.sh
```

## Systemd (production)

```bash
sudo cp deployment/systemd/openhands-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now openhands-agent
```

## Проверка

```bash
sudo /usr/bin/bash deployment/scripts/status.sh
```

## Остановка

```bash
sudo /usr/bin/bash deployment/scripts/stop.sh
```

## Полное удаление тестового запуска

```bash
sudo /usr/bin/bash deployment/scripts/purge-test.sh --confirm-destroy-test-data
```

## Доступ

```
http://10.77.0.2:8000/canvas (только WireGuard)
```

LLM настраивается через WebUI (Settings → LLM) после первого входа.

## Сетевая изоляция

Применить egress-правила:
```bash
sudo /usr/bin/bash deployment/network/apply-egress-rules.sh
```

Проверить:
```bash
sudo /usr/bin/bash deployment/network/check-egress.sh
```

## Статическая проверка

```bash
/usr/bin/bash deployment/scripts/validate-static.sh
```
