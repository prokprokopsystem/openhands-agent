# Этап 5A — Host-side Backup: сухой план

**Дата:** 26 июля 2026  
**Статус:** READ-ONLY аудит. Никаких изменений не выполнено.

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

## 3. Сравнение вариантов шифрования

### 3.1. Вариант A — GPG симметричный (рекомендован)

```bash
# Шифрование
tar czf - secrets/ | gpg -c --batch --passphrase-file /path/to/passphrase.txt -o secrets.tar.gz.gpg

# Расшифровка
gpg -d --batch --passphrase-file /path/to/passphrase.txt secrets.tar.gz.gpg | tar xzf -
```

| Плюс | Минус |
|------|-------|
| Просто: один пароль | Пароль нужно безопасно хранить |
| Не нужна генерация ключей | Компрометация пароля = доступ ко всем копиям |
| Штатный инструмент, уже установлен | |

### 3.2. Вариант B — GPG асимметричный

```bash
# Шифрование (публичным ключом)
tar czf - secrets/ | gpg --encrypt --recipient igor@prokop -o secrets.tar.gz.gpg

# Расшифровка (приватным ключом)
gpg --decrypt secrets.tar.gz.gpg | tar xzf -
```

| Плюс | Минус |
|------|-------|
| Публичный ключ можно хранить где угодно | Нужна генерация ключевой пары |
| Приватный ключ — отдельно | Управление ключами сложнее |
| Можно шифровать без пароля при каждом запуске | |

### 3.3. Вариант C — OpenSSL

```bash
# Шифрование
tar czf - secrets/ | openssl enc -aes-256-cbc -pbkdf2 -pass file:/path/to/passphrase.txt -out secrets.tar.gz.enc

# Расшифровка
openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/path/to/passphrase.txt -in secrets.tar.gz.enc | tar xzf -
```

| Плюс | Минус |
|------|-------|
| Всегда доступен | Нет сжатия внутри |
| AES-256 | Сложнее автоматизировать |

### 3.4. Сравнительная таблица

| Критерий | GPG симм. | GPG асимм. | OpenSSL |
|----------|-----------|------------|---------|
| Установлен | ✅ Да | ✅ Да | ✅ Да |
| Простота | ⭐⭐⭐ | ⭐⭐ | ⭐⭐ |
| Автоматизация | ✅ | ✅ | ⚠️ |
| Хранение ключа | Пароль в файле | Приватный ключ | Пароль в файле |
| Рекомендация | **✅** | — | — |

---

## 4. Решения, требуемые от Игоря

| # | Вопрос | Варианты |
|---|--------|----------|
| 1 | **Место backup** | А) `/mnt/amnesia-backup/openhands/` (существующий внешний диск). Б) Отдельный внешний диск |
| 2 | **Метод шифрования secrets** | А) GPG симметричный (пароль). Б) GPG асимметричный (ключи). В) OpenSSL |
| 3 | **Место хранения пароля/ключа шифрования** | Решение Игоря — Hermes не выбирает самостоятельно |
| 4 | **Шифровать ли весь архив (включая config с profiles/*.json)?** | А) Да — шифровать всё. Б) Нет — только secrets/ |
| 5 | **Тестовое восстановление: автоматическое или ручное?** | А) Автоматическое раз в неделю. Б) Ручное по запросу |

---

## 5. Что НЕ делать

- ❌ Не создавать backup-задачи, таймеры, ключи, пароли
- ❌ Не размещать backup внутри `/projects` или Git
- ❌ Не менять Compose, systemd, Canvas, firewall
- ❌ Не читать содержимое секретов
