# Infrastructure Audit — Mini-server

**Дата и время:** 25 июля 2026, 19:29 CEST  
**Исполнитель:** Hermes (read-only SSH)  
**Проект:** OpenHands Agent — Этап 0  
**Метод:** исключительно безопасные команды чтения. Ничего не установлено, не изменено, не остановлено.

---

## 1. Мини-сервер — характеристики

| Параметр | Значение |
|---|---|
| Модель | HP EliteDesk 800 G3 DM 65W (SKU: 1VF94EC#ABD) |
| Процессор | Intel Core i5-7500 @ 3.40GHz, 4 ядра, 1 сокет, без HT |
| Архитектура | x86-64 |
| RAM | 14 GB всего (2.2 GB used, 12 GB available) |
| Swap | 4 GB (не используется) |
| ОС | Ubuntu 26.04 LTS |
| Ядро | Linux 7.0.0-28-generic |
| Hostname | mini-server |
| Uptime | 3 дня 3:45 |
| Load average | 0.06 / 0.09 / 0.07 |
| CPU idle | 83% |
| systemd failed | 0 |

**Вывод:** сервер практически простаивает. CPU и RAM с большим запасом.

---

## 2. Диски

| Устройство | Модель | Размер | Тип | ФС | Mount | Занято | Свободно |
|---|---|---|---|---|---|---|---|
| /dev/sda | Goodram CX400 1TB SSD | 953.9G | SATA | LVM/ext4 | / | 24G (3%) | 873G |
| /dev/sdb | SanDisk 256GB SSD | 238.5G | USB | ext4 | /mnt/amnesia-backup | 509M (1%) | 234G |

**Детали корневого диска:**
- sda1: 1G, vfat, /boot/efi
- sda2: 2G, ext4, /boot
- sda3: 950.8G, LVM → ubuntu-vg/ubuntu-lv, ext4, /

**Свободное место:** 873 GB на корневом разделе. Более чем достаточно.

---

## 3. Docker

| Параметр | Значение |
|---|---|
| Engine | 29.1.3 |
| Compose | 2.40.3+ds1-0ubuntu1 |
| Контейнеров всего | 13 |
| Работает | 11 |
| Образов | 24 (14.68 GB, 13.48 GB reclaimable) |
| Volumes | 14 local (1.56 GB) |
| Build cache | 809 MB (378 MB reclaimable) |

---

## 4. Контейнеры и сервисы

| Контейнер | Образ | Статус | Restart | Порты | Сеть |
|---|---|---|---|---|---|
| **nextcloud-aio-mastercontainer** | all-in-one:latest | Up 3 days (healthy) | always | 192.168.100.106:8080→8080 | nextcloud-aio |
| **nextcloud-aio-apache** | aio-apache:latest | Up 39h (healthy) | unless-stopped | 10.77.0.2:11000→11000 | nextcloud-aio |
| **nextcloud-aio-nextcloud** | aio-nextcloud:latest | Up 39h (healthy) | unless-stopped | 9000 (internal) | nextcloud-aio |
| **nextcloud-aio-database** | aio-postgresql:latest | Up 39h (healthy) | unless-stopped | 5432 (internal) | nextcloud-aio |
| **nextcloud-aio-redis** | aio-redis:latest | Up 39h (healthy) | unless-stopped | 6379 (internal) | nextcloud-aio |
| **nextcloud-aio-talk** | aio-talk:latest | Up 39h (healthy) | unless-stopped | **0.0.0.0:3478** TCP+UDP | nextcloud-aio |
| **nextcloud-aio-whiteboard** | aio-whiteboard:latest | Up 39h (healthy) | unless-stopped | 3002 (internal) | nextcloud-aio |
| **nextcloud-aio-imaginary** | aio-imaginary:latest | Up 39h (healthy) | unless-stopped | — | nextcloud-aio |
| **nextcloud-aio-notify-push** | aio-notify-push:latest | Up 39h (healthy) | unless-stopped | — | nextcloud-aio |
| **nextcloud-aio-eurooffice** | aio-eurooffice:latest | Up 39h (healthy) | unless-stopped | — | nextcloud-aio |
| **nextcloud-aio-borgbackup** | aio-borgbackup:latest | Exited (0) | — | — | nextcloud-aio |
| **amnesia-bridge** | amnesia-bridge:step-15 | Up 2 days (healthy) | no (systemd) | **10.77.0.2:8090**→8090 | bridge_default (172.20.0.2) |
| **wg0** | ubuntu:24.04 | Exited (137) 6 days | no | — | host |

### Статус «не изменять»

| Сервис | Причина |
|---|---|
| Все 10 контейнеров Nextcloud AIO | Production-хранилище пользователя |
| amnesia-bridge | Проект AMNESIA — отдельный, на паузе, не изменять |
| wg0 (stopped) | Rollback-контейнер WireGuard, не удалять |
| WireGuard native | Критическая связность VPS ↔ mini-server |

---

## 5. Compose-проекты

| Проект | Путь | Контейнеров | Статус |
|---|---|---|---|
| **nextcloud** | /srv/nextcloud/compose.yaml | 11 (10 AIO + borgbackup) | running |
| **bridge** | /srv/prokop/projects/amnesia/bridge/compose.yaml | 1 (amnesia-bridge) | running |

---

## 6. Порты — все слушающие

| Порт | Интерфейс | Протокол | Сервис | Публичный |
|---|---|---|---|---|
| 22 | 0.0.0.0 | TCP | SSH | ⚠️ Да (ограничен роутером) |
| 53 | 127.0.0.53/54 | TCP+UDP | systemd-resolved | Нет |
| 3478 | 0.0.0.0 | TCP+UDP | Nextcloud Talk | ⚠️ Да (но без VPS DNAT) |
| 8080 | 192.168.100.106 | TCP | Nextcloud AIO UI | LAN only |
| 11000 | 10.77.0.2 | TCP | Nextcloud Apache | WG only |
| 8090 | 10.77.0.2 | TCP | amnesia-bridge MCP | WG only |
| 39945 | 127.0.0.1 | TCP | containerd | Нет |

### Свободные диапазоны портов (на 0.0.0.0)

Заняты только: 22, 3478. Остальные 1–65535 **свободны** на всех интерфейсах.

**Рекомендация для OpenHands:** порты 3000, 8000, 8443, 9090 — кандидаты. Избегать: 8080 (занят AIO), 11000 (Apache WG), 8090 (amnesia-bridge), 3478 (Talk).

---

## 7. Сеть

### Интерфейсы

| Интерфейс | IP | Назначение |
|---|---|---|
| eno1 | 192.168.100.106/24 | Физический LAN |
| wg0 | 10.77.0.2/24 | WireGuard → VPS |
| br-69c1b4187c12 | 172.19.0.1/16 | nextcloud-aio |
| br-c782ca870e23 | 172.18.0.1/16 | nextcloud_default |
| br-c307bfbd00e2 | 172.20.0.1/16 | bridge_default |
| docker0 | 172.17.0.1/16 | DOWN (не используется) |

### Маршруты

- default → 192.168.100.1 (домашний роутер)
- 10.77.0.0/24 → wg0 (WireGuard)

### WireGuard

- Интерфейс: wg0, 10.77.0.2/24
- Service: wg-quick@wg0.service — **enabled, active**
- Peer VPS: 10.77.0.1:51820
- Автозапуск: подтверждён reboot-тестом 19 июля 2026

### Firewall

- UFW: **inactive** (правила не добавлены)
- Фактическая фильтрация: Docker iptables + домашний роутер/NAT
- Внешний Hetzner Cloud Firewall: не проверен

---

## 8. Домены и Reverse Proxy

| Домен | Назначение | TLS | Сертификат до |
|---|---|---|---|
| prokop-agent.duckdns.org | n8n | Let's Encrypt | 22 Aug 2026 |
| cloud.prokop-agent.duckdns.org | Nextcloud | Let's Encrypt | 14 Oct 2026 |
| amnesia.prokop-agent.duckdns.org | AMNESIA MCP | Let's Encrypt (ECDSA) | 16 Oct 2026 |

Reverse proxy: **Nginx на VPS** (95.217.239.148). Все три домена терминируют TLS на VPS, далее — HTTP через WireGuard до mini-server.

---

## 9. SSH и права

### Пользователи

| Пользователь | UID | Группы | Назначение |
|---|---|---|---|
| igor | 1000 | igor, adm, cdrom, sudo, dip, plugdev, users, lxd, docker | Основной администратор |

Других пользователей (hermes, codex, amnesia) — **нет**. Hermes и Codex заходят как `igor`.

### SSH-ключи

- Каталог: `/home/igor/.ssh/` (700)
- Ключей в authorized_keys: **2**
- Hermes: `/opt/data/.ssh/id_ed25519`
- Codex: `/home/igor/.ssh/id_ed25519_codex_miniserver`

### Ограниченный sudo (Codex)

- Wrapper: `/usr/local/sbin/codex-mini-server-admin` (root:root, 750)
- sudoers: `/etc/sudoers.d/codex-mini-server` (root:root, 440)
- Разрешённые операции: status, wireguard-status, wireguard-restart, docker-status, nextcloud-status, wireguard-backup-status, reboot, shutdown (+ amnesia-bridge-service-status/start/stop/restart)

### SSH-псевдонимы (известны)

- `mini-server` → igor@192.168.100.106
- `vps-autolead` → root@95.217.239.148

---

## 10. Постоянное хранение

### Каталоги проектов

| Путь | Проект | Владелец |
|---|---|---|
| /srv/nextcloud/ | Nextcloud AIO | igor:igor |
| /srv/nextcloud/data/ | Данные Nextcloud | www-data:root |
| /srv/prokop/projects/amnesia/bridge/ | AMNESIA Bridge | igor:igor |
| /srv/prokop/projects/amnesia/backups/ | AMNESIA backups | igor:igor |
| /srv/amnesia-bridge/data/ | SQLite AMNESIA | igor:igor |
| /srv/prokop/projects/autolead/ | AutoLead (архив) | igor:igor |

### Bind mounts

| Хост | Контейнер | Назначение |
|---|---|---|
| /srv/nextcloud/data | nextcloud-aio-nextcloud:/mnt/ncdata | Файлы Nextcloud |
| /srv/amnesia-bridge/data | amnesia-bridge:/app/data | SQLite AMNESIA |

### Docker volumes (Nextcloud)

`nextcloud_aio_nextcloud`, `nextcloud_aio_database`, `nextcloud_aio_redis`, `nextcloud_aio_mastercontainer`, `nextcloud_aio_apache`, `nextcloud_aio_database_dump`, `nextcloud_aio_eurooffice`, `nextcloud_aio_backup_cache`, `nextcloud_aio_elasticsearch` + 5 анонимных.

### Внешний backup

- Устройство: /dev/sdb (SanDisk 256GB USB SSD)
- Mount: /mnt/amnesia-backup
- ФС: ext4, UUID: 641c201e-fae3-43f3-8021-9aa4a9ba819f
- fstab: `defaults,nofail,nodev,nosuid,noexec,x-systemd.device-timeout=30s`

---

## 11. Ресурсы для нового агента

### Оценка достаточности

| Ресурс | Доступно | Достаточно? |
|---|---|---|
| CPU | 4 ядра, 83% idle (~3.3 ядра свободно) | ✅ Более чем |
| RAM | 12 GB available из 14 GB | ✅ Достаточно |
| Диск | 873 GB свободно | ✅ Более чем |
| Порты | Сотни свободны | ✅ |

### Предлагаемый каталог проекта

`/srv/openhands-agent/` — новый каталог, по аналогии с `/srv/nextcloud/`. Не пересекается с AMNESIA и Nextcloud.

### Предлагаемое размещение данных

| Назначение | Путь |
|---|---|
| Проект | /srv/openhands-agent/ |
| Compose | /srv/openhands-agent/compose.yaml |
| Workspace агента | /srv/openhands-agent/workspace/ |
| Конфигурация | /srv/openhands-agent/config/ |
| Логи | /srv/openhands-agent/logs/ |
| SSH (агента) | /srv/openhands-agent/ssh/ |
| Секреты | /srv/openhands-agent/secrets/ (mode 700) |
| Backups | /mnt/amnesia-backup/openhands-agent/ |
| Данные (volume) | Docker named volume: openhands_data |

### Предполагаемые порты

| Компонент | Порт | Интерфейс |
|---|---|---|
| Веб-интерфейс | 3000 | 10.77.0.2 (WG) или 127.0.0.1 |
| API (если есть) | 3001 | 10.77.0.2 (WG) |

Публичный доступ — через Nginx на VPS, новый домен (например, `agent.prokop-agent.duckdns.org`).

---

## 12. Обнаруженные ограничения и риски

1. **UFW выключен.** При добавлении нового сервиса нужно либо настроить firewall, либо полагаться на Docker и bind-адреса.
2. **Единственный пользователь `igor`.** Для изоляции агента рекомендуется создать отдельного системного пользователя (например, `openhands`).
3. **Docker socket** доступен пользователю `igor` (группа docker). Агенту **не следует** давать доступ в группу docker — использовать отдельный socket proxy или wrapper.
4. **Talk 3478** открыт на всех интерфейсах. Публичный доступ ограничен домашним роутером, но при изменении port-forwarding может стать публичным.
5. **amnesia-bridge** использует systemd unit с `Restart=always`. При установке нового агента systemd-юниты не должны конфликтовать.
6. **docker0 DOWN** — стандартный bridge не используется. Можно удалить или оставить.
7. **Rollback-контейнер wg0** (stopped) — не удалять без отдельного решения.
8. **Нет внешнего мониторинга** ресурсов mini-server. После установки агента желателен контроль CPU/RAM/диска.

---

## 13. Что ещё нужно уточнить

- [ ] Hetzner Cloud Firewall перед VPS
- [ ] Домашний роутер — port-forwarding для 41616/UDP и 22/TCP
- [ ] Доступность IPv6 снаружи
- [ ] Какой домен использовать для OpenHands (agent.prokop-agent.duckdns.org?)
- [ ] Какую модель LLM использовать как основную
- [ ] Точные требования OpenHands к CPU/RAM (будет определено на Этапе 1)
- [ ] Нужен ли отдельный frontend (Open WebUI) или достаточно штатного GUI OpenHands

---

## 14. Предварительный вывод

**Mini-server готов к тестовой установке OpenHands Agent.**

Ресурсы (CPU, RAM, диск, порты) — с большим запасом. Все критические сервисы (Nextcloud, WireGuard, SSH) стабильны. Инфраструктура задокументирована. Новый агент может быть добавлен без конфликтов в отдельный каталог `/srv/openhands-agent/`.

---

## Рекомендуемый следующий один этап

**Этап 1: Проверка OpenHands без подключения к инфраструктуре**

- Выбрать актуальную стабильную версию OpenHands
- Создать отдельный Docker Compose в `/srv/openhands-agent/compose.yaml`
- Подключить одну внешнюю модель
- Проверить GUI с компьютера и телефона (текст, файлы, изображения, голос)
- Измерить потребление CPU, RAM и диска
- Проверить восстановление после перезапуска контейнера
- **Результат:** решение, подходит ли штатный GUI или нужен отдельный интерфейс

---

*Конец аудита. 25 июля 2026, Hermes read-only.*
