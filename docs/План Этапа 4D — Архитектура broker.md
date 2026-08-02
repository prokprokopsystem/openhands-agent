# Этап 4D — Архитектура broker

**Версия:** 2.2 (2 августа 2026)
**Статус:** ✅ `4D.0 REVIEW: PASS`; ✅ `4D.1 REVIEW: PASS`; 4D.2 remediation подготовлен после полного server audit, server migration не выполнялась
**Основа:** проверенные идеи старого 4D из `fix/canonical-deployment`, без переноса его архитектурного расползания

---

## 1. Цель

Дать Agent Canvas постоянный набор безопасных инструментов для работы с mini-server, VPS и разрешёнными сервисами. Broker — отдельный слой инструментов и полномочий, а не владелец Canvas deployment.

```text
Canvas
  │
  │ bounded JSON over protected transport
  ▼
Broker core (без target credentials)
  ├─ protocol/schema/canonicalization
  ├─ policy/risk
  ├─ audit
  └─ dispatcher
       │
       ├─ core/mini-server helpers
       ├─ VPS adapter identity + secrets
       ├─ n8n adapter identity + secrets
       ├─ GitHub adapter identity + secrets
       ├─ Nextcloud adapter identity + secrets
       ├─ Notion adapter identity + secrets
       └─ AMNESIA adapter identity + secrets
```

Canvas не получает target credentials. Broker core также не читает target credentials.

---

## 2. Жёсткая граница: base Canvas не принадлежит broker

Broker installer запрещено автоматически устанавливать или переписывать:

- `deployment/compose.yaml`;
- `deployment/scripts/prepare.sh`;
- `deployment/scripts/validate-runtime.sh`;
- `deployment/scripts/run-supervised.sh`;
- `deployment/scripts/health-watchdog.sh`;
- `deployment/network/*`;
- `deployment/systemd/openhands-agent.service`;
- Nginx / Basic Auth / certificates;
- server-side Canvas profiles, LLM config и conversations;
- Telegram gateway;
- backup infrastructure;
- WireGuard;
- файлы других проектов вне точного adapter/tool contract.

`setup-broker` устанавливает только broker artifacts. Если исправление broker требует изменить соседний слой — STOP и сначала изменение плана.

### 2.1. Единственное исключение — Canvas Connector

Connector — отдельный минимальный patch base deployment, необходимый только для связи Canvas → broker:

1. read-only mount client credential/transport material;
2. read-only pinned host trust material;
3. точное сетевое разрешение только для broker endpoint;
4. connector validation.

Connector не входит в broker installer и принимается отдельным этапом.

### 2.2. Recovery после Connector

Текущий recovery SHA `de2244dd68e8036e5b6917cb994c83e507855a1a` является **pre-connector baseline**.

Этап Connector не считается завершённым, пока одновременно не выполнено:

- connector patch зафиксирован отдельным commit SHA;
- перечислены все изменённые base files и их pre-connector hashes;
- подготовлен и проверен отдельный connector rollback;
- подготовлена recovery-процедура, которая восстанавливает base **вместе с connector**;
- новый `canonical base + connector SHA` записан в `docs/План.md` и `docs/Состояние.md`;
- `de2244dd...` сохранён как pre-connector fallback, но больше не используется как обычный recovery после freeze connector.

Следующий recovery не должен молча отключать broker connection.

---

## 3. Что берём из старого 4D

Переиспользуем после review:

- отдельный host user `openhands-broker`;
- SSH public-key authentication как transport;
- `authorized_keys` restrictions + `sshd Match User` + `ForceCommand`;
- запрет TTY, forwarding, password и interactive auth;
- pinned ED25519 host key и strict host verification;
- allowlist tools;
- строгую валидацию параметров;
- A/B/C risk model;
- fail-closed journald audit;
- bounded input/output и timeout;
- root-owned broker files;
- узкие helpers/sudoers;
- negative tests;
- отдельные credentials по target.

Не переносим:

- старый `setup-broker.sh`, доставляющий Canvas lifecycle/base files;
- broker как владелец compose/prepare/validate/watchdog/systemd Canvas;
- arbitrary shell templates из registry;
- `bash -c` над registry/user input;
- общий `secrets.d`, читаемый broker core;
- передачу request params через shell parsing `SSH_ORIGINAL_COMMAND`;
- автоматическое расширение scope при исправлении ошибки.

---

## 4. Wire protocol v1

SSH — только transport. Request data не передаётся в remote command line.

### 4.1. Forced-command contract

- `authorized_keys`/`Match User` всегда запускают фиксированный broker launcher;
- non-empty `SSH_ORIGINAL_COMMAND` отклоняется: параметры через него запрещены;
- launcher не делает `eval`, word splitting или shell parsing request data;
- launcher запускает core с очищенным окружением (`env -i`) и фиксированными `PATH`, `HOME`, locale;
- client-controlled environment variables не принимаются;
- server-derived metadata (например peer address) может быть передана core только после нормализации launcher-ом.

### 4.2. Request

Один UTF-8 JSON object через stdin. Максимальный размер request: **16 KiB**.

```json
{
  "version": 1,
  "request_id": "uuid",
  "tool": "n8n_workflow_get",
  "params": {},
  "approval_id": null
}
```

Требования:

- неизвестные top-level fields → reject;
- `version` только поддерживаемая версия;
- `request_id` валидный UUID;
- `tool` — registry name;
- `params` — только JSON object и только поля schema конкретного tool;
- `approval_id` отсутствует/null для A/B; для C — только установленного формата;
- duplicate JSON keys, invalid UTF-8, oversized input, trailing second object → reject.

### 4.3. Canonicalization

До policy/approval broker строит canonical request descriptor:

```text
protocol_version + target + tool + adapter + operation + canonical_params
```

Canonical params создаются только после schema validation: фиксированные типы, детерминированный порядок ключей, без shell/string interpolation. Этот descriptor используется для audit и approval hash.

### 4.4. Response

Один bounded JSON object, максимум **64 KiB**:

```json
{
  "version": 1,
  "request_id": "uuid",
  "status": "ok|error|rejected",
  "result": null,
  "error": null
}
```

Secret values запрещены в response, audit и diagnostics.

---

## 5. Broker core и registry

Broker core выполняет только:

1. принимает bounded JSON;
2. валидирует protocol/schema;
3. canonicalizes request;
4. находит tool;
5. проверяет risk/approval;
6. пишет mandatory STARTED audit;
7. dispatches фиксированный adapter + operation;
8. применяет timeout/output bounds;
9. принимает structured result/verify/rollback result;
10. пишет final audit.

Registry модульный:

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

Registry содержит только contract metadata:

```yaml
name: n8n_workflow_get
target: n8n
adapter: n8n
operation: workflow_get
risk: A
params: {}
timeout: 30
output_limit: 65536
```

Registry не содержит shell commands, executable templates или secrets.

---

## 6. Adapter isolation и credentials

### 6.1. Core не читает target secrets

`openhands-broker` и broker core не состоят в группах target secrets и не имеют read permission к ним.

Каждый credential-bearing adapter получает отдельную Unix identity, например:

```text
openhands-adapter-vps
openhands-adapter-n8n
openhands-adapter-github
openhands-adapter-nextcloud
openhands-adapter-notion
openhands-adapter-amnesia
```

Secrets разделены:

```text
/etc/openhands-broker/secrets.d/vps/*
/etc/openhands-broker/secrets.d/n8n/*
/etc/openhands-broker/secrets.d/github/*
...
```

Каждый каталог доступен только root и соответствующей adapter identity/group. Один adapter не может читать secrets другого target.

### 6.2. Dispatch

Core вызывает только фиксированный root-owned adapter executable. Для adapter identity используется узкое правило запуска точного executable (например exact sudo rule или отдельный Unix service/socket). Никакого `sudo sh`, произвольного executable path или shell string.

Request adapter-у также передаётся bounded JSON через stdin.

Adapter повторно проверяет:

- своё имя target;
- допустимую operation;
- target-specific parameter constraints;
- output bounds.

То есть adapter не полагается только на policy core.

### 6.3. Privileged host helpers

Операции, которым реально нужен root, реализуются отдельными root-owned helpers с фиксированными операциями. Общего root shell adapter нет.

---

## 7. Risk model и DEC-022

### Level A — автоматически

Только read-only/diagnostics. Состояние target не меняется.

### Level B — автоматически только project-scoped reversible writes

Примеры:

- запись в allowlisted project path;
- изменение allowlisted n8n workflow;
- commit/push в разрешённую non-protected branch;
- разрешённое изменение Notion/Nextcloud/AMNESIA объекта.

Для B применяются pre-check, backup/idempotence, verify, rollback и audit там, где это возможно.

**Любые изменения system services через `systemctl` не являются Level B.** В соответствии с DEC-022 любые `start/stop/restart/enable/disable` system service до отдельного изменения DEC остаются Level C и требуют явного подтверждения.

### Level C — только one-time approval

Сюда входят как минимум:

- любые system service mutations;
- firewall;
- SSH/system users;
- disks/storage;
- base Canvas deployment/lifecycle;
- Nginx/certificates;
- production/main/protected branches;
- secrets/credential rotation;
- массовое удаление;
- backup infrastructure;
- необратимые операции.

До PASS approval subsystem Level C технически disabled.

---

## 8. Level C approval subsystem

Approval не является файлом, который broker/Canvas может создать сам.

### 8.1. Ownership

```text
/run/openhands-broker/approvals/     root:root 0700
/run/openhands-broker/inflight/      root:root 0700
/run/openhands-broker/consumed/      root:root 0700
```

Broker core и Canvas не имеют write/read/list доступа к approval directories.

### 8.2. Trusted creator

Отдельный root-owned creator, например:

`/usr/local/sbin/openhands-broker-approve`

Он вызывается оператором только после явного разрешения пользователя. Request descriptor получает bounded JSON через stdin, а не shell interpolation.

Creator canonicalizes request и создаёт approval с полями:

- approval_id;
- protocol version;
- target;
- tool;
- hash canonical request descriptor;
- created_at;
- expiry;
- random nonce.

Файл создаётся в том же filesystem через secure temp/open с `O_CREAT|O_EXCL|O_NOFOLLOW`, проверенным owner/mode, `fsync`, затем atomic rename. Итог: regular file `root:root 0600`.

### 8.3. Trusted consumer/executor

Отдельный root-owned consumer/executor. Broker core может вызвать только его точный executable через узкое правило. Consumer получает approval_id + canonical request через bounded JSON stdin. Он не возвращает broker core переносимый grant или иной результат, который core мог бы подделать и предъявить privileged helper.

Consumer:

1. открывает approval directory через trusted directory fd;
2. запрещает symlink/path traversal (`openat`/`O_NOFOLLOW`, regular-file `fstat`, owner `uid=0`, mode `0600`);
3. атомарно claims approval перемещением `approvals/<id>` → `inflight/<id>` на том же filesystem; второй consumer после этого не может получить тот же capability;
4. проверяет expiry, nonce/id format, target, tool и exact canonical request hash;
5. mismatch/expired → reject и capability не возвращается в available state;
6. после успешной проверки в той же root-controlled execution boundary вызывает только фиксированный Level C helper/operation, привязанный к canonical descriptor;
7. capability считается consumed независимо от результата операции и атомарно переносится в `consumed/` либо удаляется согласно retention policy;
8. возвращает broker core только structured result уже выполненной операции, без capability contents и secrets.

### 8.4. Невозможность обхода core-ом

Consume и запуск exact Level C operation находятся в одной root-controlled execution boundary. Между consumer и privileged helper нет доверия к данным, возвращаемым broker core, и никакой reusable/synthetic grant через core не проходит. Одного утверждения core «approval был» недостаточно. Таким образом компрометация core не превращает Level C helper в безусловный root executor.

---

## 9. Audit

Journald tag `openhands-broker`.

Минимум:

- request_id;
- tool/target/adapter/operation;
- risk;
- canonical non-secret params или их безопасное представление;
- status;
- duration;
- result code;
- verify/rollback status;
- approval_id для C без capability contents.

Если mandatory STARTED audit недоступен, state-changing operation не выполняется. Secret values запрещены.

---

## 10. Обязательные архитектурные тесты

1. broker installer не доставляет base Canvas files;
2. `SSH_ORIGINAL_COMMAND` не используется для request params; non-empty remote command rejected;
3. request — только bounded JSON stdin;
4. registry не содержит executable shell strings/`bash -c`;
5. user params не превращаются в command line shell;
6. неизвестный tool/adapter/operation/parameter → fail-closed;
7. broker core не может читать target secrets;
8. adapter A не может читать credential adapter B;
9. adapter повторно проверяет target/operation;
10. systemctl mutations отсутствуют в A/B;
11. Level C без trusted one-time approval → reject;
12. approval creator/consumer directories root-only, symlink/race/single-use tests PASS, а core не может подделать grant между consume и execute;
13. secrets отсутствуют в fixtures/output/audit;
14. uninstall broker не меняет base Canvas;
15. connector recovery test доказывает, что canonical recovery после Connector сохраняет broker connection.

---

## 11. Реализация по этапам

### 4D.0 — Архитектура и границы ✅ REVIEW PASS

Этот документ и `docs/План.md`.

Архитектурные границы v2.2 проверены по broker/base separation, порядку этапов, wire protocol, credential isolation, Level C trust boundary, DEC-022 и connector recovery. 4D.1 разрешено начинать как repository-only этап в указанном ниже scope.

### 4D.1 — Broker Core v2 (repository-only)

**Статус: ✅ `4D.1 REVIEW: PASS`; 35/35 unit/negative tests и local process-path PASS.**

- wire protocol v1;
- forced-command launcher contract;
- bounded JSON parser/schema/canonicalization;
- modular registry;
- dispatcher;
- fixed adapter interface;
- A/B/C policy (B/C fail-closed до этапов 4D.6/4D.8);
- audit;
- core adapter `ping/capabilities`;
- unit/negative tests.

Scope: `deployment/broker/**` + документы 4D/Состояние. Base deployment не меняется.

### 4D.2 — Host installation v2 + isolation foundation

**Статус: 🟡 exact frozen-v1 migration package исправлен после первого остановленного preflight; повторный server preflight/application ещё не выполнены.**

Installer устанавливает только broker artifacts:

- broker Unix identity;
- сохранение frozen legacy client keypair без chmod/chown/перезаписи;
- отдельный broker v2 client key и его public key с точной ownership/mode policy `10001:10001 0600` для private key;
- restricted `authorized_keys` entry для broker identity;
- pinned host trust material, проверенное против фактической host key;
- fixed launcher/core;
- broker directories;
- sshd forced-command policy;
- root-owned registry;
- per-adapter Unix identities/directories;
- narrow helper/sudo policy;
- audit prerequisites;
- Level C directories, но C остаётся disabled.

`--preflight-only` является строго observational: не создаёт lock/temp/key files и не
пишет audit event. Apply snapshot содержит before-hashes фиксированного списка base
Canvas lifecycle/network files; validation, rollback и uninstall подтверждают их
неизменность.

Uninstall удаляет только broker artifacts.

Файлы base Canvas на этом этапе не меняются. Client credential и pinned trust material только подготавливаются для последующего read-only mount в 4D.4.

### 4D.3 — Mini-server Level A implementation + host-only acceptance

На этом этапе реализуются `mini_server` adapter и его Level A registry contracts, после чего до Canvas Connector проверяются host-side:

- protocol/forced command;
- `ping/capabilities`;
- read-only mini-server tools;
- credential isolation negative tests;
- no-shell/no-extra-target tests.

Это **не** end-to-end Canvas acceptance. Acceptance не начинается, пока adapter/tools текущего этапа не реализованы и не установлены через broker-only installer/update path.

### 4D.4 — Canvas Connector + recovery freeze

Отдельный minimal base patch.

Acceptance включает:

- connector works;
- base files вне connector scope unchanged;
- connector rollback works;
- новый canonical `base + connector SHA` зафиксирован;
- новая recovery процедура проверена;
- `de2244dd...` остаётся только pre-connector fallback.

### Operator-mediated bootstrap до 4D.8

4D.2 изменяет system user/SSH/sudo policy, а 4D.4 изменяет строго перечисленные base Canvas/network files. По DEC-022 это Level C действия. До появления approval subsystem они выполняются только доверенным оператором вне Canvas/broker после отдельного точного разрешения пользователя.

Canvas и broker core не могут запускать, повторять или самоподтверждать 4D.2/4D.4. Наличие installer/connector scripts в репозитории не является разрешением на их применение.

### 4D.5 — Canvas → broker Level A end-to-end

Только после 4D.4 Canvas реально вызывает broker через wire protocol v1. Проверяются A tools и negative transport/policy tests из Canvas.

### 4D.6 — Level B project-scoped writes

Добавляются только заранее перечисленные обратимые project writes. Systemctl mutations сюда не входят.

Первый acceptance — безопасная тестовая операция вне base Canvas.

### 4D.7 — Service adapters

Каждый отдельно: VPS → n8n → GitHub → Nextcloud → Notion → AMNESIA.

Для каждого: отдельная identity, credential boundary, allowlist, tests, acceptance.

### 4D.8 — Level C approval subsystem

Реализуются trusted creator + atomic trusted consumer/executor + exact binding + TTL + single-use + race/symlink protection. Никакой grant через broker core не передаётся. После PASS разрешается первый заранее выбранный C test; до этого C disabled.

### 4D.9 — End-to-end acceptance и freeze 4D v1

Проверяются:

- Canvas→broker A;
- B reversible write;
- неизвестная операция/target reject;
- credential isolation;
- no secret leakage;
- rollback after verify failure;
- C без approval reject;
- C с approval выполняется ровно один раз и только exact request;
- повтор approval reject;
- restart Canvas не ломает connector;
- restart broker не ломает Canvas;
- canonical recovery сохраняет connector;
- uninstall broker не меняет base deployment.

После этого фиксируется `4D v1` commit/tag.

---

## 12. Что не является задачей 4D

Отдельно решаются:

- LLM/profile Canvas;
- browser Basic Auth;
- Telegram UI/voice;
- Nginx;
- Agent Canvas version update;
- backup redesign;
- WireGuard redesign.

Ошибка соседнего слоя не является разрешением переписывать broker или base deployment.

---

## 13. Критерий готовности

4D готов только после 4D.9 и frozen v1. До этого любой статус — промежуточный.
