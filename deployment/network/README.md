# Сетевая изоляция тестового OpenHands

Подсеть контейнера фиксирована: `10.89.0.0/28`, адрес контейнера `10.89.0.2`.

Правила применяются только к этой подсети через отдельные цепочки:

- `OPENHANDS-EGRESS`, переход из `DOCKER-USER`;
- `OPENHANDS-INPUT`, переход из `INPUT`.

## Политика

Разрешены:

- ответы `ESTABLISHED,RELATED`;
- только `10.89.0.2 → 10.89.0.1:22` для forced-command broker;
- DNS TCP/UDP 53;
- внешний HTTP/HTTPS TCP 80/443.

Запрещены:

- mini-server и Docker gateway, кроме точного broker endpoint `10.89.0.1:22`;
- WireGuard и сети `10.0.0.0/8`;
- LAN `192.168.0.0/16`;
- чужие Docker-сети `172.16.0.0/12`;
- CGNAT/link-local/loopback;
- VPS `95.217.239.148`;
- все остальные публичные порты;
- IPv6 внутри контейнера.

Порядок правил детерминирован. Ошибки не подавляются. Скрипты идемпотентны.

## Жизненный цикл

Правила не применяются вручную при штатной эксплуатации. `openhands-agent.service` выполняет последовательность:

1. подготовка каталогов;
2. ожидание `wg0` и адреса `10.77.0.2`;
3. статическая проверка Compose;
4. `docker compose create` без запуска;
5. применение сетевых правил;
6. запуск Compose в foreground.

При остановке контейнер сначала останавливается, затем `ExecStopPost` удаляет только правила OpenHands.

## Ручная проверка после запуска

Запускать на хосте:

```bash
bash /srv/openhands-agent/deployment/network/check-egress.sh
```

Скрипт сам выполняет сетевые команды через `docker exec openhands-agent`. Он проверяет доступность только broker SSH на Docker gateway, внешний HTTPS и блокировку AMNESIA, Nextcloud, альтернативного SSH mini-server, LAN-роутера, VPS, публичного SSH и IPv6.

## Аварийное удаление правил

```bash
sudo /srv/openhands-agent/deployment/network/remove-egress-rules.sh
```
