# Этап 4D — Финальная архитектура broker

**Версия:** 2.0 (2 августа 2026)  
**Статус:** ✅ архитектура утверждена; реализация начинается только по этапам этого документа  
**Основа:** рабочие идеи старого 4D из `fix/canonical-deployment`, без переноса его архитектурного расползания

---

## 1. Цель

Дать Agent Canvas постоянный набор безопасных инструментов для работы с mini-server, VPS и разрешёнными сервисами так, чтобы агент мог выполнять обычную работу самостоятельно, но не мог произвольно получить shell/root-доступ, секреты или начать перестраивать инфраструктуру.

4D — это **отдельный слой инструментов**, а не новый владелец Canvas deployment.

Главный принцип:

```text
Canvas
  │
  │ один защищённый локальный канал
  ▼
Broker на mini-server
  ├─ policy / registry
  ├─ audit
  ├─ adapters
  ├─ secrets (host-side)
  └─ approvals для Level C
       │
       ├─ mini-server
       ├─ VPS
       ├─ n8n
       ├─ GitHub
       ├─ Nextcloud
       ├─ Notion
       └─ AMNESIA
```

Canvas не получает прямые credentials этих систем. Все внешние операции идут через broker/adapters.

---

## 2. Жёсткая граница: base Canvas НЕ принадлежит 4D

После recovery базовый Canvas снова считается отдельным стабильным слоем.

### 4D broker запрещено автоматически переписывать или устанавливать:

- `deployment/compose.yaml`;
- `deployment/scripts/prepare.sh`;
- `deployment/scripts/validate-runtime.sh`;
- `deployment/scripts/run-supervised.sh`;
- `deployment/scripts/health-watchdog.sh`;
- `deployment/network/*`;
- `deployment/systemd/openhands-agent.service`;
- Nginx / Basic Auth / сертификаты;
- server-side Canvas profiles, conversations и LLM config;
- Telegram gateway;
- backup infrastructure;
- WireGuard;
- файлы других проектов, если нет отдельного adapter/tool для конкретного проекта.

`setup-broker.sh` **не имеет права владеть lifecycle Canvas и не имеет права доставлять файлы base deployment**.

### Единственное исключение — отдельный одноразовый Canvas Connector

Чтобы Canvas мог вызвать broker, допускается один отдельно проверяемый connector-patch базового deployment:

1. read-only mount приватного client key broker;
2. read-only pinned `known_hosts`;
3. точное сетевое разрешение только `Canvas 10.89.0.2 → host 10.89.0.1:22`;
4. проверки этих трёх условий.

Connector устанавливается **отдельно от broker setup**, один раз, после чего снова считается частью frozen base deployment.

Любая другая необходимость изменить base Canvas означает STOP и изменение этого плана до кода.

---

## 3. Что берём из старого 4D

Старую ветку не переносим целиком. Переиспользуем только проверенные идеи и, где возможно, код после повторного review:

- отдельный host user `openhands-broker`;
- SSH public-key authentication;
- `authorized_keys` restriction + `sshd Match User` + `ForceCommand`;
- запрет TTY, forwarding, password и interactive auth;
- отдельный client key;
- pinned ED25519 host key и `StrictHostKeyChecking=yes`;
- allowlist инструментов;
- строгая валидация параметров;
- A/B/C risk model;
- fail-closed audit в journald;
- bounded output / timeout;
- root-owned broker files;
- узкие sudo/helper операции вместо широкого sudo;
- negative tests на injection, неизвестные команды, лишние параметры и secrets leakage;
- отдельные credentials для разных targets.

### Что из старого 4D НЕ переносим

- `setup-broker.sh`, который начинает устанавливать compose/lifecycle scripts Canvas;
- broker как владелец `prepare.sh`, `validate-runtime.sh`, watchdog или systemd unit Canvas;
- автоматическое «починить ещё один base-файл, потому что broker его потребовал»;
- один разрастающийся install script как центр всей архитектуры;
- произвольные shell templates из registry, выполняемые через `bash -c`;
- прямое монтирование всех host secrets в Canvas;
- автоматическое расширение scope во время исправления отдельной ошибки.

---

## 4. Финальные компоненты 4D

### 4.1. Broker transport

Canvas имеет только один credential: ключ подключения к локальному broker.

```text
Canvas 10.89.0.2
   │ SSH, StrictHostKeyChecking=yes
   ▼
10.89.0.1:22
   │ sshd Match User + ForceCommand
   ▼
openhands-broker
```

Обычный shell невозможен даже при прямом вызове SSH.

### 4.2. Broker core

Пути:

```text
/usr/local/lib/openhands-broker/broker-wrapper
/usr/local/lib/openhands-broker/adapters/
/etc/openhands-broker/tools.d/
/etc/openhands-broker/secrets.d/
/run/openhands-broker/
```

Broker core выполняет только:

1. разбирает запрос;
2. находит tool в registry;
3. валидирует параметры;
4. проверяет risk/approval;
5. пишет обязательный audit STARTED;
6. вызывает фиксированный adapter + operation;
7. ограничивает время и размер вывода;
8. запускает verify;
9. при предусмотренном сценарии запускает rollback;
10. пишет финальный audit result.

### 4.3. Registry — декларативный, модульный

Вместо одного огромного `tools.yaml`:

```text
/etc/openhands-broker/tools.d/core.yaml
/etc/openhands-broker/tools.d/mini-server.yaml
/etc/openhands-broker/tools.d/vps.yaml
/etc/openhands-broker/tools.d/n8n.yaml
/etc/openhands-broker/tools.d/github.yaml
/etc/openhands-broker/tools.d/nextcloud.yaml
/etc/openhands-broker/tools.d/notion.yaml
/etc/openhands-broker/tools.d/amnesia.yaml
```

Registry **не содержит произвольный shell command**.

Tool описывает только контракт:

```yaml
name: n8n_workflow_get
adapter: n8n
operation: workflow_get
risk: A
params: ...
timeout: 30
output_limit: 65536
lock_scope: n8n
requires_backup: false
verify: true
rollback: false
```

Фактическая реализация находится в фиксированном adapter, а не в строке `bash -c` из YAML.

### 4.4. Adapters

Каждый target — отдельный adapter с фиксированным набором операций.

Adapter:

- принимает только нормализованные argv/JSON от broker core;
- не исполняет переданный пользователем shell;
- сам читает нужные host-side secrets;
- имеет target allowlist;
- возвращает структурированный status/result;
- отдельно тестируется.

Первоначальный набор adapters:

- `core` — ping/version/capabilities;
- `mini_server` — диагностика и разрешённые операции mini-server;
- `vps` — через отдельный restricted SSH credential;
- `n8n` — API конкретного n8n instance и allowlisted workflows;
- `github` — только разрешённые repositories/branches/operations;
- `nextcloud` — только выделенные рабочие paths;
- `notion` — только разрешённые databases/pages;
- `amnesia` — операции, относящиеся только к AMNESIA.

### 4.5. Secrets

Secrets остаются только на host-side.

Пример:

```text
/etc/openhands-broker/secrets.d/n8n/api-token
/etc/openhands-broker/secrets.d/github/token
/etc/openhands-broker/secrets.d/vps/id_ed25519
```

Правила:

- secrets не передаются Canvas;
- secrets не находятся в registry;
- secrets не пишутся в stdout/stderr/audit/Git;
- adapter получает secret по фиксированному имени;
- один target — отдельный credential;
- rotation одного credential не ломает остальные adapters.

### 4.6. Audit

Journald, tag `openhands-broker`.

Минимальные поля:

- request_id;
- timestamp;
- tool;
- adapter/operation;
- risk;
- нормализованные non-secret params;
- status;
- duration;
- exit/result code;
- rollback status при наличии.

Если обязательный STARTED audit записать нельзя — write operation не выполняется.

---

## 5. Risk model

### Level A — автоматически

Только read-only и диагностика:

- статусы;
- журналы в разрешённых границах;
- disk/memory/network checks;
- чтение конфигурации без secret values;
- чтение разрешённых n8n workflows;
- чтение разрешённых GitHub/Nextcloud/Notion/AMNESIA объектов;
- health/tests.

Level A не меняет состояние target.

### Level B — автоматически в разрешённом проектном контуре

Ограниченные обратимые изменения, если tool заранее описан и имеет необходимые safety hooks:

- изменение файла только в allowlisted project path;
- изменение разрешённого n8n workflow;
- commit/push только в разрешённую non-protected branch;
- операции AMNESIA через её adapter;
- обновление разрешённого Notion/Nextcloud объекта;
- restart конкретной project-службы, если она явно включена в allowlist и это не base Canvas/SSH/firewall/storage.

Для Level B обязательно, когда применимо:

1. pre-check;
2. backup/snapshot или доказанная идемпотентность;
3. operation;
4. verify;
5. rollback;
6. audit.

### Level C — только по отдельному пользовательскому разрешению

- firewall;
- SSH/system users;
- disks/storage;
- base Canvas deployment/lifecycle;
- Nginx/certificates;
- production/main/protected branches;
- новые secrets/credential rotation;
- массовое удаление;
- backup infrastructure;
- необратимые операции.

**Level C не имеет постоянного разрешения.**

Для него используется one-time approval capability:

```text
/run/openhands-broker/approvals/<id>.json
```

Approval создаётся доверенным operator path после явной команды пользователя и содержит:

- точный tool;
- hash нормализованных params;
- expiry;
- одноразовый nonce/id.

Broker принимает capability только один раз и атомарно помечает consumed. Canvas сам себе approval создать не может.

До реализации approval mechanism Level C остаётся технически заблокирован.

---

## 6. Защита от повторения старой ошибки проекта

Для 4D действуют обязательные архитектурные тесты:

1. `setup-broker` не содержит установки/замены base Canvas deployment files.
2. Broker registry не содержит `bash -c`, произвольных command templates и исполняемых строк из пользовательских параметров.
3. Base Canvas write-операции отсутствуют в A/B registry.
4. Secrets отсутствуют в fixtures, logs, dry-run и output.
5. Неизвестный tool/adapter/operation/parameter всегда fail-closed.
6. Level C без валидного one-time approval всегда fail-closed.
7. Удаление broker не меняет base Canvas и другие проекты.
8. Один adapter нельзя использовать для доступа к target другого adapter.
9. Исправление одного adapter не даёт права менять broker core или base deployment без отдельного изменения плана.

Если для исправления бага требуется выйти за разрешённые файлы текущего этапа — STOP.

---

## 7. Реализация по этапам

### 4D.0 — Архитектура и границы ✅

Этот документ + запись в общем `docs/План.md`.

Результат: до начала кода определено, что является broker, а что не является broker.

### 4D.1 — Broker Core v2 (repository-only)

Берём старый broker как исходный материал и делаем новый core без зависимости от base Canvas deployment.

Разрешённый scope изменений:

```text
deployment/broker/**
docs/План Этапа 4D — Финальная архитектура broker.md
docs/Состояние.md
```

Требования:

- forced-command wrapper;
- modular `tools.d`;
- adapter dispatcher;
- без `bash -c` registry execution;
- strict params schema;
- timeout/output bounds;
- journald audit;
- A/B/C policy engine;
- Level C пока fail-closed;
- unit/negative tests.

**Запрещено:** менять compose, prepare, runtime validator, network, systemd Canvas.

Acceptance: repository tests PASS и diff не выходит за разрешённый scope.

### 4D.2 — Host installation v2

Создать маленький идемпотентный installer только для broker host artifacts:

- `openhands-broker` user;
- `/usr/local/lib/openhands-broker`;
- `/etc/openhands-broker`;
- sshd Match User / authorized_keys;
- узкие helpers/sudoers;
- audit prerequisites.

Installer не касается base Canvas files.

Acceptance: повторный install ничего не ломает; uninstall удаляет только broker artifacts.

### 4D.3 — Mini-server Level A

Подключить и проверить только read-only tools:

- ping/capabilities;
- service status для allowlisted project services;
- bounded journal logs;
- docker/container status без изменения;
- disk/memory;
- project-specific health checks.

Acceptance: все A tools работают; negative tests не дают shell/extra target access.

### 4D.4 — Одноразовый Canvas Connector

Отдельный минимальный patch base deployment:

- client key RO mount;
- pinned known_hosts RO mount;
- точный egress/host access `10.89.0.2 → 10.89.0.1:22`;
- validation.

Никакого другого изменения base Canvas.

После acceptance connector считается frozen.

### 4D.5 — Mini-server Level B

Добавляются только заранее перечисленные project-scoped write tools.

Первый acceptance выполняется на безопасной тестовой операции, не на Canvas base.

Каждый B tool должен иметь собственный pre-check/verify/rollback contract.

### 4D.6 — Service adapters

Каждый adapter вводится отдельным подэтапом и отдельным acceptance:

1. VPS;
2. n8n;
3. GitHub;
4. Nextcloud;
5. Notion;
6. AMNESIA.

Новый adapter не меняет уже принятые adapters и broker transport.

### 4D.7 — Level C one-time approval

Реализовать host-side approval capability с exact tool+params hash, TTL и single-use consumption.

До PASS этого этапа Level C остаётся disabled.

### 4D.8 — End-to-end acceptance и freeze v1

Пользователь даёт реальные задачи разных классов.

Проверяется:

- A read-only;
- B обратимое изменение;
- отказ неизвестной операции;
- отказ доступа к чужому target;
- отсутствие secret leakage;
- rollback после искусственного verify failure;
- Level C без approval → reject;
- Level C с одноразовым approval → ровно одна разрешённая операция;
- restart Canvas не ломает broker connection;
- restart broker не ломает Canvas;
- uninstall broker не меняет base deployment.

После этого `4D v1` получает frozen tag/commit и считается завершённым.

---

## 8. Что НЕ является задачей 4D

Отдельно от 4D решаются:

- текущая настройка LLM/profile Canvas;
- browser Basic Auth;
- развитие Telegram UI/voice;
- изменение Nginx;
- обновление Agent Canvas версии;
- переделка backup;
- изменение WireGuard;
- общие изменения AMNESIA, если они не выполняются через уже утверждённый AMNESIA adapter.

Ошибка в одном из этих слоёв не является причиной переписывать broker.

---

## 9. Критерий готовности

4D не считается готовым потому, что «broker запустился» или «одна команда сработала».

4D завершён только после 4D.8, когда существует стабильная цепочка:

```text
задача пользователя
→ Canvas
→ broker policy
→ adapter
→ target
→ verify/rollback/audit
→ результат пользователю
```

и при этом base Canvas остаётся отдельным независимым слоем.

---

**Правило проекта:** сначала меняется этот план, затем код. Код не имеет права сам расширять архитектуру 4D.