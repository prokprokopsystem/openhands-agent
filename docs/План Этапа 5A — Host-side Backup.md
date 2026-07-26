# Этап 5A — Host-side Backup ✅

**Дата:** 26 июля 2026  
**Статус:** ✅ Реализован и проверен.

---

## 1. Аудит текущего состояния

### 1.1. Размеры каталогов `/srv/openhands-agent/`

| Каталог | Размер | Файлов | Содержит |
|---------|--------|--------|----------|
| `config/` | 7.0 MB | 120 | Профили, settings, беседы, bash-история |
| `work-workspace/` | 8.0 KB | 1 | Рабочие файлы агента |
| `docs/` | 72 KB | 6 | Копия документации проекта |
| `deployment/` | 128 KB | 20 | Compose, скрипты, systemd, firewall |
| `secrets/` | 8.0 KB | 1 | `.env` (LOCAL_BACKEND_API_KEY) |
| **Итого** | **~7.2 MB** | **148** | |

Данные очень малы — полный архив помещается на любой носитель.

### 1.2. Доступные диски

| Устройство | ФС | Объём | Исп. | Своб. | Точка монтирования | Назначение |
|-----------|-----|-------|------|-------|-------------------|------------|
| `/dev/sda` (SSD) | ext4 (LVM) | 936 GB | 30 GB | 867 GB | `/` | Системный |
| `/dev/sdb1` (внешний) | ext4 | 234 GB | 509 MB | 234 GB | `/mnt/amnesia-backup` | Резерв AMNESIA |

### 1.3. Вывод

- Системный SSD (`/`) — использовать **только для временных точек отката** перед изменениями. Не для постоянных резервных копий.
- Внешний диск `/dev/sdb1` (234 GB, 1% заполнен) — пригоден для резервных копий OpenHands. Уже используется для AMNESIA. Предложение: подкаталог `/mnt/amnesia-backup/openhands/`.
- Общий объём данных OpenHands — **~7.2 MB**. 30 дней ротации займут ~220 MB.

### 1.4. Доступные инструменты шифрования

| Инструмент | Версия | Плюсы | Минусы |
|-----------|--------|-------|--------|
| **GPG симметричный** | 2.4.8 | Парольная фраза, просто, не нужен ключевой файл | Пароль нужно где-то хранить |
| **GPG асимметричный** | 2.4.8 | Публичный ключ для шифрования, приватный для расшифровки | Нужна генерация и хранение ключевой пары |
| **OpenSSL** | 3.x | `openssl enc -aes-256-cbc`, штатный инструмент | Сложнее автоматизировать |

**Рекомендация:** GPG симметричный (`gpg -c --batch --passphrase ...`). Парольную фразу хранить отдельно (вне репозитория и вне mini-server). Это решение принимает Игорь.

---

## 2. План резервного копирования

### 2.1. Что архивируется

| Каталог | Метод | Шифрование |
|---------|-------|-----------|
| `config/` | `tar czf` | ❌ Без шифрования (не содержит ключей, кроме `profiles/*.json` — остаточный риск Canvas) |
| `work-workspace/` | `tar czf` | ❌ Без шифрования |
| `docs/` | `tar czf` | ❌ Без шифрования (копия публичной документации) |
| `deployment/` | `tar czf` | ❌ Без шифрования |
| `secrets/` | `tar czf` + `gpg -c` | ✅ Отдельный зашифрованный архив |

**Важно:** `config/` содержит `profiles/*.json` с API-ключами LLM. Включено в общий архив без шифрования — это остаточный риск. Альтернатива: шифровать весь архив целиком.

### 2.2. Что НЕ архивируется

- ❌ Никакого backup внутри самого контейнера или `/projects`
- ❌ Никакого backup в Git (секреты не должны попадать в репозиторий)
- ❌ Docker-образы (перекачиваются из реестра)
- ❌ Логи контейнера (ротируются Docker)

### 2.3. Механизм выполнения

**systemd timer** (не cron, не агент):

```
/etc/systemd/system/openhands-backup.service   — скрипт backup
/etc/systemd/system/openhands-backup.timer     — расписание
```

Преимущества systemd timer над cron:
- Журнал в `journalctl`
- Зависимости (After=openhands-agent.service)
- `OnCalendar=daily` с `RandomizedDelaySec=1800`

### 2.4. Структура backup

```
/mnt/amnesia-backup/openhands/
├── daily/
│   ├── openhands_backup_2026-07-26.tar.gz
│   ├── openhands_secrets_2026-07-26.tar.gz.gpg
│   └── ...
├── weekly/
│   ├── openhands_backup_2026-W30.tar.gz
│   └── ...
├── pre_change/
│   └── openhands_pre_2026-07-26_10-30.tar.gz   (ручной, перед APPLY)
└── backup.log
```

### 2.5. Ротация

| Тип | Хранить | Очистка |
|-----|---------|---------|
| Ежедневные | 7 копий | `find daily/ -mtime +7 -delete` |
| Еженедельные | 4 копии | `find weekly/ -mtime +28 -delete` |
| Pre-change | 10 копий | Ручная очистка |

### 2.6. Проверка архива

После каждого backup:
```bash
tar tzf backup.tar.gz >/dev/null 2>&1 && echo "OK" || echo "CORRUPT"
```

Тестовое восстановление — раз в неделю в `/tmp/openhands-restore-test/`.

### 2.7. Журнал

Формат `backup.log` (без ключей и токенов):
```
2026-07-26 10:00:00 daily  openhands_backup_2026-07-26.tar.gz 7.2M OK
2026-07-26 10:00:05 daily  openhands_secrets_2026-07-26.tar.gz.gpg 0.1M OK
```

### 2.8. Процедура восстановления

```bash
# 1. Остановить службу
sudo systemctl stop openhands-agent

# 2. Восстановить из архива
sudo tar xzf /mnt/amnesia-backup/openhands/daily/openhands_backup_YYYY-MM-DD.tar.gz -C /tmp/restore/
sudo rsync -a /tmp/restore/srv/openhands-agent/ /srv/openhands-agent/

# 3. Расшифровать и восстановить secrets
gpg -d /mnt/amnesia-backup/openhands/daily/openhands_secrets_YYYY-MM-DD.tar.gz.gpg | sudo tar xz -C /tmp/restore-secrets/
sudo rsync -a /tmp/restore-secrets/srv/openhands-agent/secrets/ /srv/openhands-agent/secrets/

# 4. Запустить службу
sudo systemctl start openhands-agent
```

### 2.9. Процедура отключения

```bash
sudo systemctl disable --now openhands-backup.timer
# Архивы на внешнем диске сохраняются, не удаляются
```

---

## 3. Реализация

### 3.1. Скрипт: `/usr/local/bin/openhands-backup.sh`

- Архив `tar.gz` всего `/srv/openhands-agent/`, исключая symlink `backups`
- Проверка `mountpoint -q /mnt/amnesia-backup` перед запуском
- Ротация: `find -mtime +7 -delete` (daily), `find -mtime +28 -delete` (weekly)
- Еженедельная копия по воскресеньям (копия daily)
- Журнал: `/mnt/amnesia-backup/openhands-agent/backup.log`

### 3.2. systemd timer

- `openhands-backup.timer`: `OnCalendar=daily`, `RandomizedDelaySec=1800`, `Persistent=true`
- `openhands-backup.service`: `Type=oneshot`, `User=root`, `After=openhands-agent.service`

### 3.3. Результаты теста

| Проверка | Результат |
|---|---|
| Архив | 2.0 MB, `tar tzf` — OK |
| Восстановление | `/tmp/openhands-restore-test/` — структура и все файлы на месте |
| symlink исключён | ✅ Нет рекурсии |
| Timer | Активен, следующий запуск — завтра |

---

## 4. Процедура восстановления

```bash
sudo systemctl stop openhands-agent
sudo tar xzf /mnt/amnesia-backup/openhands-agent/daily/openhands_YYYY-MM-DD.tar.gz -C /tmp/restore/
sudo rsync -a /tmp/restore/openhands-agent/ /srv/openhands-agent/
sudo systemctl start openhands-agent
```

## 5. Что НЕ делать

- ❌ Не размещать backup внутри `/projects` или Git
- ❌ Не запускать backup без внешнего диска
- ❌ Не трогать резервные копии других проектов на диске
