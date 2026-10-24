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

Скрипт: [scripts/restore-canvas-ssh.py](scripts/restore-canvas-ssh.py). Запуск: `sudo python3 /path/to/restore-canvas-ssh.py` из зафиксированного коммита. Подготовлен пакет; результат на сервере пока не подтверждён.

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

Текущие compose.yaml и apply-egress-rules.sh в Git соответствуют применённому SSH-изменению. Server check-egress.sh ещё старый: ожидает блокировку gateway SSH. В Git ожидаемая проверка исправлена на доступность; синхронизировать серверный checker отдельно, не разворачивать весь deployment ради одного файла. GitHub CLI установлен, постоянная авторизация ещё не завершена.


## Постоянное хранение авторизации GitHub CLI

**Подготовлено 24 октября; применение ещё не подтверждено.** GH_CONFIG_DIR задаётся как /home/openhands/.openhands/gh и тем самым использует существующий постоянный config mount. Он соответствует /srv/openhands-agent/config/gh на хосте. Наличие gh CLI не означает авторизацию. Сначала настроить постоянный каталог, затем проверить сохранившийся вход и только при его отсутствии выполнять вход в существующий GitHub account.

Однократное применение на проверенном mini-server (без создания backup/token, остальные secrets не менять):

```bash
sudo python3 - <<'PY'
import pathlib, os, subprocess, time
f = pathlib.Path('/srv/openhands-agent/deployment/compose.yaml')
original = f.read_text()
anchor = '    env_file:\n'
if original.count(anchor) != 1 or '    environment:' in original:
    raise SystemExit('СТОП: Compose отличается от ожидаемого')
if 'image: openhands-agent-canvas-ssh:1.6.1-restored' not in original:
    raise SystemExit('СТОП: образ Canvas изменился')
folder = pathlib.Path('/srv/openhands-agent/config/gh')
if folder.is_symlink() or (folder.exists() and not folder.is_dir()):
    raise SystemExit('СТОП: неожиданный объект config/gh')
folder.mkdir(exist_ok=True)
os.chown(folder, 10001, 10001)
folder.chmod(0o700)
updated = original.replace(anchor,
    '    environment:\n      GH_CONFIG_DIR: /home/openhands/.openhands/gh\n\n'+anchor, 1)
attempted_restart = False
try:
    f.write_text(updated)
    subprocess.run(['docker','compose','-f',str(f),'config','--quiet'], check=True)
    print('Сохраняю постоянный каталог gh. Перезапуск только OpenHands...', flush=True)
    attempted_restart = True
    subprocess.run(['systemctl','restart','openhands-agent'], check=True, timeout=240)
    for _ in range(60):
        r = subprocess.run(['docker','exec','openhands-agent','printenv','GH_CONFIG_DIR'],
            capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip() == '/home/openhands/.openhands/gh':
            break
        time.sleep(2)
    else:
        raise RuntimeError('Новая настройка не появилась в контейнере')
except Exception:
    f.write_text(original)
    if attempted_restart:
        subprocess.run(['systemctl','restart','openhands-agent'], timeout=240)
    raise SystemExit('НЕ ПРОЙДЕНО: возвращён исходный Compose')
print('ПРОЙДЕНО: GH_CONFIG_DIR=/home/openhands/.openhands/gh')
r = subprocess.run(['docker','exec','openhands-agent','gh','auth','status','--hostname','github.com'],
    capture_output=True, text=True)
print(r.stdout)
print(r.stderr)
PY
```

Если gh сообщает not logged in после настройки каталога, это ожидаемый незавершённый шаг. Не записывать токен в Compose/Git/.env; следующий вход gh будет сохранять свои credentials в указанном постоянном runtime directory. Нельзя считать доступ к приватному репозиторию или запись в него проверенными по одному существованию hosts.yml.
