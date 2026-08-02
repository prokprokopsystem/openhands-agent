#!/usr/bin/bash
# OpenHands Agent Canvas — runtime-проверка
# Обязательный ExecStartPre для systemd.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
SECRETS_FILE="${BASE}/secrets/.env"
BROKER_KEY="${BASE}/secrets/openhands-broker-v2/id_ed25519"
BROKER_TRUST="/etc/openhands-broker/client_known_hosts"
CONNECTOR_IMAGE="openhands-agent-canvas-broker:1.6.1-4d4"
CONNECTOR_STATE="/var/lib/openhands-broker/connector-state.json"
CONTAINER_UID="10001"
CONTAINER_GID="10001"
HOST_UID="$(id -u igor)"
HOST_GID="$(id -g igor)"

ok()   { printf '  [OK] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; exit 1; }

echo "=== Runtime validation ==="

docker info >/dev/null 2>&1 || fail "Docker недоступен"
ok "Docker доступен"

docker compose version >/dev/null 2>&1 || fail "docker compose отсутствует"
ok "docker compose"

ip link show wg0 >/dev/null 2>&1 || fail "Интерфейс wg0 не существует"
ip addr show wg0 | grep -q '10.77.0.2' || fail "Адрес 10.77.0.2 не найден на wg0"
ok "wg0: 10.77.0.2"

[ -f "${COMPOSE_FILE}" ] || fail "${COMPOSE_FILE} не существует"
ok "compose.yaml"

for d in config secrets work-workspace logs; do
    DIR="${BASE}/${d}"
    [ -d "${DIR}" ] || fail "${DIR} не существует. Запустите prepare.sh"
    P=$(stat -c "%a" "${DIR}")
    [ "${P}" = "700" ] || fail "${DIR} права ${P}, требуется 700"
done
ok "Каталоги: 700"

for d in config work-workspace; do
    DIR="${BASE}/${d}"
    U=$(stat -c "%u" "${DIR}")
    G=$(stat -c "%g" "${DIR}")
    [ "${U}:${G}" = "${CONTAINER_UID}:${CONTAINER_GID}" ] \
        || fail "${DIR} владелец ${U}:${G}, требуется ${CONTAINER_UID}:${CONTAINER_GID}"
done
ok "Bind mounts: владелец ${CONTAINER_UID}:${CONTAINER_GID}"

for d in secrets logs; do
    DIR="${BASE}/${d}"
    U=$(stat -c "%u" "${DIR}")
    G=$(stat -c "%g" "${DIR}")
    [ "${U}:${G}" = "${HOST_UID}:${HOST_GID}" ] \
        || fail "${DIR} владелец ${U}:${G}, требуется ${HOST_UID}:${HOST_GID} (igor)"
done
ok "Хостовые каталоги: владелец igor"

[ -f "${SECRETS_FILE}" ] || fail "${SECRETS_FILE} не существует"
P=$(stat -c "%a" "${SECRETS_FILE}")
[ "${P}" = "600" ] || fail "${SECRETS_FILE} права ${P}, требуется 600"

COUNT=$(grep -cE '^LOCAL_BACKEND_API_KEY=.*' "${SECRETS_FILE}" || true)
[ "${COUNT}" -eq 1 ] || fail "${SECRETS_FILE}: найдено ${COUNT} строк LOCAL_BACKEND_API_KEY, нужна ровно 1"

KEY=$(grep -E '^LOCAL_BACKEND_API_KEY=.*' "${SECRETS_FILE}" | head -1 | cut -d'=' -f2-)
[ -n "${KEY}" ] || fail "LOCAL_BACKEND_API_KEY пуст"
[ ${#KEY} -ge 16 ] || fail "LOCAL_BACKEND_API_KEY слишком короткий: ${#KEY} символов, минимум 16"

for p in your-generated-key-here changeme example placeholder; do
    [ "${KEY}" != "${p}" ] || fail "LOCAL_BACKEND_API_KEY совпадает с шаблоном '${p}'"
done

echo "${KEY}" | grep -q '\*\*\*' && fail "LOCAL_BACKEND_API_KEY содержит ***, не заменён" || true
echo "${KEY}" | grep -q '[[:space:]]' && fail "LOCAL_BACKEND_API_KEY содержит пробелы" || true

ok "LOCAL_BACKEND_API_KEY задан, длина ${#KEY}"

for connector_file in "${BROKER_KEY}" "${BROKER_TRUST}"; do
    [ -f "${connector_file}" ] && [ ! -L "${connector_file}" ] \
        || fail "Connector file отсутствует или является symlink: ${connector_file}"
    [ "$(stat -c '%u:%g:%a' "${connector_file}")" = "0:10001:640" ] \
        || fail "Connector file metadata mismatch: ${connector_file}"
done
ok "Broker connector files: root:10001 0640"

docker image inspect "${CONNECTOR_IMAGE}" >/dev/null 2>&1 || fail "Connector image отсутствует"
[ "$(docker image inspect --format '{{ index .Config.Labels \"org.openhands.connector.stage\" }}' "${CONNECTOR_IMAGE}")" = "4D.4" ] \
    || fail "Connector image label mismatch"
[ -f "${CONNECTOR_STATE}" ] && [ ! -L "${CONNECTOR_STATE}" ] \
    || fail "Connector state отсутствует или является symlink"
[ "$(stat -c '%U:%G:%a' "${CONNECTOR_STATE}")" = "root:root:600" ] \
    || fail "Connector state metadata mismatch"
CONNECTOR_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["commit"])' "${CONNECTOR_STATE}")"
CONNECTOR_IMAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["image_id"])' "${CONNECTOR_STATE}")"
[ "$(docker image inspect --format '{{ index .Config.Labels \"org.openhands.connector.source\" }}' "${CONNECTOR_IMAGE}")" = "${CONNECTOR_COMMIT}" ] \
    || fail "Connector image source mismatch"
[ "$(docker image inspect --format '{{.Id}}' "${CONNECTOR_IMAGE}")" = "${CONNECTOR_IMAGE_ID}" ] \
    || fail "Connector image ID mismatch"
ok "Connector image"

for s in run-supervised.sh health-watchdog.sh prepare.sh; do
    [ -f "${BASE}/deployment/scripts/${s}" ] || fail "${s} не найден"
done
ok "Lifecycle-скрипты"

for s in apply-egress-rules.sh remove-egress-rules.sh check-egress.sh; do
    [ -f "${BASE}/deployment/network/${s}" ] || fail "network/${s} не найден"
done
ok "Firewall-скрипты"

docker compose -f "${COMPOSE_FILE}" config >/dev/null 2>&1 || fail "docker compose config не прошёл"
ok "docker compose config"

echo ""
echo "=== Validation PASSED ==="
