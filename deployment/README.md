# Статус инструкции — 24 октября 2026

Выполняется восстановление без дополнительного broker/connector (DEC-023). Deployment в main пока не согласован с восстановленным mini-server; команды ниже относятся к прежнему развёртыванию и не являются инструкцией повторной установки поверх работающего сервера. Не применять их массово до согласования. Текущее действие и подтверждённые результаты: [Состояние проекта](../docs/Состояние.md).

---

# OpenHands Agent Canvas — развёртывание

**Единственная инструкция установки.** Другие документы — канонические решения и архитектура.

## Первая установка и изолированный тестовый запуск

Это включает: копирование на mini-server, подготовку каталогов, создание ключа, установку systemd unit, скачивание образа, запуск контейнера, настройку LLM через WebUI, тест в пустом test-workspace.

### 1. Подготовка

На рабочем компьютере:

```bash
# Подготовить staging в домашнем каталоге и скопировать deployment
ssh mini-server 'rm -rf ~/openhands-agent-stage && mkdir -p ~/openhands-agent-stage'
scp -r deployment mini-server:~/openhands-agent-stage/

# Открыть постоянную SSH-сессию
ssh mini-server
```

Все дальнейшие команды до конца инструкции выполняются внутри этой SSH-сессии на mini-server. Команды с `sudo` запросят пароль пользователя `igor` локально в терминале; пароль нельзя передавать Hermes или записывать в команду.

Внутри SSH-сессии:

```bash
# Перенести deployment в /srv без вложенности deployment/deployment
sudo mkdir -p /srv/openhands-agent
sudo cp -a ~/openhands-agent-stage/deployment /srv/openhands-agent/
sudo chown -R igor:igor /srv/openhands-agent/deployment
rm -rf ~/openhands-agent-stage

# Проверить каноническую структуру
test -f /srv/openhands-agent/deployment/compose.yaml
```

### 2. Секретный .env (ДО первого prepare.sh)

Создать `/srv/openhands-agent/secrets/.env` (mode 600) с двумя переменными.
Операция выполняется только при первой установке.
Существующий `.env` никогда не перезаписывается.

```bash
# Создать каталог для секретов
sudo mkdir -p /srv/openhands-agent/secrets
sudo chown igor:igor /srv/openhands-agent/secrets
sudo chmod 700 /srv/openhands-agent/secrets

# Создать .env (только если не существует)
if [ ! -f /srv/openhands-agent/secrets/.env ]; then
    # LOCAL_BACKEND_API_KEY генерируется автоматически
    LK=$(openssl rand -base64 32 | tr -d '\n')
    # DEEPSEEK_API_KEY: вводится скрыто, не попадает в историю и не выводится
    echo "Enter DeepSeek API key (https://platform.deepseek.com/api_keys):"
    read -s DK
    echo ""
    # Записать обе переменные. Значения не выводятся.
    sudo printf 'LOCAL_BACKEND_API_KEY=%s\nDEEPSEEK_API_KEY=%s\n' "$LK" "$DK" \
      > /srv/openhands-agent/secrets/.env
    sudo chmod 600 /srv/openhands-agent/secrets/.env
    echo ".env created (mode 600)."
else
    echo ".env already exists — skipping."
fi
```

После создания `.env` — запустить `prepare.sh`:

```bash
sudo /usr/bin/bash /srv/openhands-agent/deployment/scripts/prepare.sh
```

`prepare.sh` создаст runtime-каталоги, назначит `config/` и `work-workspace/` владельцу `10001:10001` (пользователь `openhands` внутри контейнера) и вызовет `seed-config.sh` для развёртывания конфигурации Canvas из шаблонов с подстановкой `DEEPSEEK_API_KEY`. `secrets/` и `logs/` остаются у пользователя `igor`. Не заменяйте эти права общим `chown -R igor:igor /srv/openhands-agent`.

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

Проверить: чат, файлы, фото, остановку задачи, потребление CPU/RAM, egress-изоляцию (через check-egress.sh).

Обязательный тест постоянства: настроить LLM, создать тестовую запись/задачу, перезапустить службу через `systemctl` и подтвердить, что настройка и данные сохранились без повторного ввода ключей. Если после перезапуска настройки исчезли, TEST MODE не считается пройденным.

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

### 10. Завершение SSH-сессии

```bash
exit
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
  ├─ SIGTERM: supervisor → watchdog stop → compose down → сбор обоих PID
  └─ ExecStopPost: compose down --remove-orphans → remove-egress-rules.sh
```

## Ключевые решения

- **Запуск:** только через systemd (`systemctl start/stop`). `docker compose up -d` запрещён.
- **Firewall:** контейнер стартует ТОЛЬКО после применения egress-правил.
- **Watchdog:** 3×unhealthy → перезапуск через systemd Restart=on-failure.
- **Healthcheck:** `/canvas` HTTP 200 + TCP-проверка портов 18000/18001. TCP = доступность порта, не функциональная readiness API.
- **LLM:** через шаблоны конфигурации (`deployment/config/`), не через env. Модель: `deepseek/deepseek-v4-pro`.
- **Авторизация:** `LOCAL_BACKEND_API_KEY` передаётся frontend автоматически. Экрана ручного ввода нет. Защита — WireGuard.
- **Секреты:** только в `/srv/openhands-agent/secrets/.env` (mode 600). Не в Git.
- **GitHub воспроизводимость:** `prepare.sh` → `seed-config.sh` разворачивает конфигурацию Canvas из шаблонов с подстановкой `DEEPSEEK_API_KEY` из `secrets/.env`.

## Секреты, задаваемые пользователем

Перед запуском создать `/srv/openhands-agent/secrets/.env` (mode 600) с двумя переменными:

| Переменная | Назначение | Получить |
|---|---|---|
| `LOCAL_BACKEND_API_KEY` | Доступ к Agent Canvas API | `openssl rand -base64 32 \| tr -d '\n'` |
| `DEEPSEEK_API_KEY` | DeepSeek LLM API | https://platform.deepseek.com/api_keys |

Шаблон: `deployment/.env.example`.

## Как GitHub восстанавливает конфигурацию Canvas

1. `prepare.sh` создаёт каталоги и вызывает `seed-config.sh`.
2. `seed-config.sh` читает `DEEPSEEK_API_KEY` из `secrets/.env`.
3. Копирует шаблоны из `deployment/config/` → `/srv/openhands-agent/config/`.
4. Заменяет `DEEPSEEK_API_KEY_PLACEHOLDER` на реальный ключ.
5. Устанавливает права `10001:10001`, mode 600.

Результат после `prepare.sh`:
- `config/agent-profiles/default.json` — UUID-профиль с 10 инструментами WORK MODE, critic_enabled: true, RU system_message_suffix
- `config/profiles/deepseek-chat.json` — модель `deepseek/deepseek-v4-pro`, base_url `https://api.deepseek.com/v1`
- `config/settings.json` — `active_profile: deepseek-chat`, `active_agent_profile_id: 2e07efc4-...`

Существующая конфигурация не перезаписывается. Для принудительного обновления: `seed-config.sh --force`.


## Восстановление постоянного SSH из сохранённых компонентов — 24 октября 2026

Применять только к проверенному mini-server и показанному исходному compose/network. Это разовый операторский шаг; далее агент использует обычную команду `ssh mini-server`. Новый broker и новый keypair не нужны.

Скрипт: [scripts/restore-canvas-ssh.py](scripts/restore-canvas-ssh.py). Запуск: `sudo python3 /path/to/restore-canvas-ssh.py` из зафиксированного коммита. Пакет применён 24 октября; успешный результат приведён ниже. Повторное применение не требуется.

Предусловия: сохранённый image 293042314e9e с SSH/Git/gh; исходный базовый Canvas запущен; ключ root:10001 0640 и публичная часть сохранены; публичная часть уже разрешена в authorized_keys igor. Доверие к серверу берётся с его локального ED25519 host key, не через отключение StrictHostKeyChecking.

Изменения:
- локальный alias сохранённого image, без build/pull;
- /srv/openhands-agent/ssh-client/{config,known_hosts}, root:10001, только чтение для контейнера;
- прежний private key монтируется только для чтения в /run/openhands-ssh-key;
- два mounts и client image в действующем Compose, pull_policy never;
- только SSH из 10.89.0.2 к 10.89.0.1:22 в OPENHANDS-INPUT, с сохранением правила при запуске службы.

Проверки: тест обычного SSH в сетевом namespace текущего Canvas до его переключения; после применения — healthy и реальный hostname/id через SSH из контейнера. Меняется только OpenHands. Сохранённый image содержит прежний broker-client executable, но обычный SSH его не вызывает и host broker не восстанавливается. Это локальный сохранённый image, его наличие необходимо при будущем восстановлении/очистке образов.

Скрипт возвращает исходные compose/network из памяти при ошибке и пытается запустить прежний Canvas; файловые backup-копии не создаются. Не редактирует LLM/config/workspace/.env/Telegram и не применяет общий firewall reset. Авторизацию gh проверить и восстановить отдельно: установка CLI не означает наличие GitHub-доступа.


### Результат применения SSH-пакета — 24 октября

**ПРОЙДЕНО:** restore-canvas-ssh.py из f23db19 выполнен; Canvas healthy, реальный SSH после пересоздания вернул mini-server и uid=1000(igor). Image alias указывает на сохранённый ID sha256:293042314e9e535e63c2c65f8df591e3eb545c5d781e402efb799b8a2a5d5a21. Это локальный image, не опубликованный registry artifact; не удалять его при будущей очистке. Повторно запускать восстановление поверх успешной конфигурации не требуется.

Текущие compose.yaml и apply-egress-rules.sh в Git соответствуют применённому SSH-изменению. Server check-egress.sh ещё старый: ожидает блокировку gateway SSH. В Git ожидаемая проверка исправлена на доступность; синхронизировать серверный checker отдельно, не разворачивать весь deployment ради одного файла. GitHub CLI авторизован через постоянный каталог; проверка после повторного перезапуска службы пройдена, см. следующий раздел.


## Постоянное хранение авторизации GitHub CLI

**Применено и проверено 24 октября 2026. Повторный login сейчас не нужен.**

В сервисе openhands задано:

```yaml
environment:
  GH_CONFIG_DIR: /home/openhands/.openhands/gh
```

Каталог находится внутри существующего bind mount /srv/openhands-agent/config → /home/openhands/.openhands. Host path: /srv/openhands-agent/config/gh; owner 10001:10001 (openhands), mode 700. Не удалять и не заменять его при пересоздании контейнера. Дополнительный том не нужен.

Применение выполнено самим OpenHands через существующий SSH: создан каталог, точечно изменён Compose, config --quiet завершился с exit 0. Пользователь перезапустил только службу OpenHands, затем один раз выполнил вход в существующий аккаунт через gh auth login --hostname github.com --git-protocol https --web. CLI сохранил credentials в постоянном hosts.yml. Ошибка запуска Chromium не помешала завершить device flow через браузер пользователя.

После повторного перезапуска службы сам OpenHands выполнил:

```bash
ssh mini-server hostname
gh auth status --hostname github.com
gh api repos/prokprokopsystem/amnesia-next --jq '.permissions.push'
```

Получены mini-server, активный аккаунт prokprokopsystem с конфигом /home/openhands/.openhands/gh/hosts.yml и true. Это проверка доступности и разрешений; реальная запись в репозиторий не выполнялась. Новый container ID в финальном отчёте не измерялся.

При обычной работе с домашнего или рабочего компьютера открывать Canvas; SSH и GitHub используются агентом на сервере. Повторный вход потребуется только при фактической потере/отзыве авторизации. Не повторять настройку заранее. Не выводить hosts.yml и не записывать credentials в Compose/Git/.env.

Ранее подготовленная inline-команда изменения Compose удалена из текущей инструкции: настройка уже применена. Её история сохранена в Git; запуск поверх действующей конфигурации не нужен.


## Постоянные PDF-инструменты и совместная проверка QET/PDF — разрешено 24 октября 2026

**Статус: требования и порядок реализации; НЕ установленный комплект.** Пользователь прямо разрешил добавить постоянные инструменты не только чтения, но и обработки/создания PDF. После применения проверить одну цепь P04, затем расширять объём по результату.

### Набор и размещение

- Poppler (poppler-utils): pdfinfo, pdftotext, pdftoppm/pdftocairo, pdfimages.
- PyMuPDF: рендер страниц/фрагментов, текст с координатами, изображения и аннотации.
- pypdf: страницы, объединение/разделение/поворот, метаданные и обычные PDF-формы.
- ReportLab и шрифты с кириллицей/польскими буквами (DejaVu/Noto): создание отчётов, таблиц и новых PDF.
- Tesseract с eng/pol/rus: OCR сканов и текстовый слой. OCR не восстанавливает достоверно электрическую топологию и не заменяет QET или просмотр страницы.
- qpdf: структурная проверка PDF и операции с документами.

Устанавливать в производный Docker image от фактически работающего сохранённого образа openhands-agent-canvas-ssh:1.6.1-restored. Сверить его ID с текущим контейнером до сборки; не возвращать исходный bare Canvas. Не менять версии Canvas/SDK, модель или профиль. Python-зависимости изолировать от Python окружения backend (например, /opt/pdf-tools/venv); задокументировать команду их вызова. Не подменять системный python3 или backend PATH вслепую.

Сохранить в Git Dockerfile, точные выбранные версии Python-пакетов, источник базового image и инструкции сборки. Зафиксировать фактические версии системных пакетов и ID итогового образа. Build context содержит только необходимые исходники; не включать config, gh, secrets и проекты в image/layers. В Ubuntu хоста и других контейнерах пакеты не устанавливать.

### Применение без повторной настройки

1. Использовать существующий клон репозитория; прочитать текущие правила/документы и учесть открытый PR #2. Полную ревизию сервера и уже завершённые проверки инструментов не повторять.
2. Собрать image, пока действующий Canvas продолжает работать; проверить инструменты в одноразовом контейнере без credentials и производственных данных. Без массовой очистки Docker.
3. До переключения зафиксировать код/инструкцию, старый image reference/ID и точную команду отката. Сохранённый рабочий образ не удалять; не создавать архивы/копии каталогов.
4. Менять в действующем Compose только image reference на проверенный новый image (локальный образ: pull_policy never). Сохранить mounts, UID/GID, ports, limits, healthcheck, env_file, GH_CONFIG_DIR, SSH trust/key и lifecycle через существующую службу.
5. Перезапустить только OpenHands через существующий systemd lifecycle; краткий перерыв Canvas ожидаем и должен быть заранее обозначен пользователю. Если требует пароль sudo, подготовить всё и дать владельцу одну конкретную команду; пароль не запрашивать у модели, не добавлять sudoers/wrapper и не обходить доступ через privileged container.
6. После переключения подтвердить healthy, новый image ID, PDF-tools от обычного пользователя контейнера, SSH, gh auth и выбранный DeepSeek. При неуспехе вернуть предыдущий image reference и только службу OpenHands. AMNESIA, Nextcloud, Telegram, firewall и хостовый Docker не перенастраивать.

### Проверки набора

В одной task-owned временной папке выполнить полезные функциональные пробы: создать двухстраничный PDF с кириллицей/польским текстом, извлечь текст, отрисовать страницу и фрагмент, объединить/разделить/повернуть страницы и проверить результат qpdf. Отдельно OCR растрового образца с проверкой распознанного текста. Сохранить короткие результаты, удалить только созданные пробой временные материалы. Не выдавать успешный import или --version за функциональную проверку.

Затем отрисовать существующий /projects/P04-training/лист 07.pdf и открыть реальное изображение модели/пользователю средствами Canvas. Агент должен описать фактически видимые обозначения и сопоставить их с XML; самогенерированная известная картинка не подтверждает независимое чтение схемы. Если изображение не передаётся выбранной модели, явно сообщить ограничение, не утверждать, что просмотр выполнен.

### Правило работы со схемами

- Использовать QET и PDF одной актуальной редакции: фиксировать пути, даты/хеши, лист и источники. При расхождении версий сначала указать его.
- Строить связность по размещённым элементам, реальным выводам и conductor endpoints; не путать определения символов с размещёнными аппаратами.
- Сверять видимые метки и номера выводов на PDF и реальные связи QET с MASTER/I/O и принятыми решениями. Старые скрытые имена custom symbols не считать идентификацией: в P04 A1 — PLC, а не БП; PS1 — БП.
- Визуально проверять узлы, пересечения, подписи и межлистовые ссылки; при нечитаемости использовать увеличенный фрагмент. PDF-текст и OCR сами по себе не доказывают соединение.
- Отделять требования исходного заказчика, данные производителя, учебные допущения и непроверенное. Не переоткрывать исправленные исторические замечания без проверки свежих файлов.
- Первое испытание: одна цепь управления Y1 листа 07. Самостоятельно проследить вывод A1 → клемму X6 → Y1 и возврат 0 V, сравнить QET/PDF/MASTER. Дать доказательства со ссылками на лист/фрагмент и endpoints, а не только «всё правильно». Параметры цепи заранее не подсказывать как якобы найденные.
- Исходники и Nextcloud не изменять. Дальнейший тест обнаружения ошибки проводить только на явно обозначенном одноразовом учебном экземпляре с заранее учтённым изменением; текущая установка не разрешает редактирование оригинальных электрических схем.
- Правила закрепить в инструкции рабочего проекта и явно читать при новом диалоге. MASTER остаётся единственным, не создавать конкурирующую копию решений. /projects/P04-training — один постоянный рабочий каталог; повторно файлы без изменений не скачивать, промежуточные рендеры держать отдельно и не плодить каталоги-копии.

### Отчёт и границы доказанного

В Git отличать подготовку, сборку, применение, функциональные проверки и результат цепи. Обновить Состояние/План, инструкцию и действующий паспорт amnesia-next (существующий PR #1); в репозитории openhands-agent реализацию вести одним связным PR с кодом и документацией. Не утверждать равенство качества с Codex только по наличию инструментов. Качество чтения и поиска ошибок оценивается отдельным практическим испытанием.

Официальные руководства: https://pymupdf.readthedocs.io/en/latest/recipes-images.html ; https://pypdf.readthedocs.io/en/stable/user/merging-pdfs.html ; https://pypdf.readthedocs.io/en/stable/user/forms.html ; https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html ; https://qpdf.readthedocs.io/en/stable/cli.html ; https://docs.reportlab.com/reportlab/userguide/ .


## Порядок обновления, принятия версии и уборки — 25 октября 2026

Пользователь согласовал постоянное правило эксплуатации. [Единственный текущий реестр и полные критерии находятся в паспорте инфраструктуры](https://github.com/prokprokopsystem/amnesia-next/blob/infra/mini-server-revision-2026-10-24/Инфраструктура/Состояние.md), раздел 11 «Порядок обновления и уборки среды OpenHands». Здесь — инструкция применения, а не вторая таблица версий.

Перед изменением прочитать реестр; выбрать способ добавления инструмента (скрипт/постоянное окружение/API либо системный image), собрать один кандидат и проверить его. Обновление не должно порождать отдельный работающий контейнер для каждого инструмента. Зафиксировать применение и точные ID в той же работе. Сохранять одну предыдущую версию для отката; зависимые базы/слои учитывать с назначением, не удалять принудительно.

Версию принимать только после семи полных суток и трёх реальных завершённых заданий при подтверждённой работе Canvas/подключений/файлов/новых инструментов и без связанных неразобранных сбоев. Записать «ВЕРСИЯ ПРИНЯТА» с доказательствами, затем адресно убрать ненужные артефакты в разрешённом объёме; если препятствие реально есть, указать конкретную причину и следующий шаг. Сам возраст, dangling-тег или отсутствие Compose-метаданных не доказывают ненужности.

Серверная автоочистка, таймер или cron этим документом не устанавливаются. Backup-ротация и проекты имеют отдельные правила; их данные не удалять как старые images. В текущей работе только обновлена документация, ничего на сервере не удалялось. Ветки паспорта и PDF-реализации пока находятся в открытых PR #1 и #3; после слияния ссылки/актуальное местонахождение реестра согласовать без создания копий.
