# Сетевая egress-изоляция OpenHands Agent

## Подсеть

OpenHands использует фиксированную Docker-подсеть: **10.89.0.0/28**

Правила применяются ТОЛЬКО к этой подсети. Другие контейнеры не затрагиваются.

## Политика

| Трафик | Разрешён |
|---|---|
| DNS (53/udp, 53/tcp) | ✅ |
| Исходящий HTTPS (443/tcp) | ✅ |
| 10.0.0.0/8 (включая WG) | ❌ |
| 192.168.0.0/16 (LAN) | ❌ |
| 172.16.0.0/12 (Docker-сети) | ❌ |
| localhost хоста | ❌ |

## Скрипты

- `apply-egress-rules.sh` — применить правила (требует sudo)
- `check-egress.sh` — проверить изоляцию (изнутри контейнера)
- `remove-egress-rules.sh` — удалить только правила OpenHands (требует sudo)

## Применение

```bash
sudo bash deployment/network/apply-egress-rules.sh
```

Правила действуют до перезагрузки. Для постоянного применения — добавить в iptables-persistent или аналог (этап эксплуатации).

## Проверка

```bash
# Изнутри контейнера:
docker exec openhands-agent bash deployment/network/check-egress.sh

# Или с хоста:
bash deployment/network/check-egress.sh
```

## Удаление

```bash
sudo bash deployment/network/remove-egress-rules.sh
```
