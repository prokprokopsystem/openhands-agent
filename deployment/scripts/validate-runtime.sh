#!/usr/bin/bash
# OpenHands Agent Canvas — runtime-проверка
# Обязательный ExecStartPre для systemd.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
SECRETS_FILE="${BASE}/secrets/.env"
BROKER_KEY="${BASE}/secrets/broker-mini-server.key"
BROKER_KNOWN_HOSTS="/etc/openhands-broker/client_known_hosts"
HOST_KEY_PUBLIC="/etc/ssh/ssh_host_ed25519_key.pub"
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

for d in config secrets test-workspace logs; do
    DIR="${BASE}/${d}"
    [ -d "${DIR}" ] || fail "${DIR} не существует. Запустите prepare.sh"
    P=$(stat -c "%a" "${DIR}")
    [ "${P}" = "700" ] || fail "${DIR} права ${P}, требуется 700"
done
ok "Каталоги: 700"

for d in config test-workspace; do
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

[ -f "${BROKER_KEY}" ] || fail "${BROKER_KEY} не существует"
BROKER_KEY_STATE="$(stat -c '%u:%g:%a' "${BROKER_KEY}")"
[ "${BROKER_KEY_STATE}" = "0:10001:640" ] \
    || fail "${BROKER_KEY}: ${BROKER_KEY_STATE}, требуется root:10001 640"
ok "Broker key доступен только root и container GID 10001"

[ -f "${BROKER_KNOWN_HOSTS}" ] || fail "${BROKER_KNOWN_HOSTS} не существует"
KNOWN_HOSTS_STATE="$(stat -c '%u:%g:%a' "${BROKER_KNOWN_HOSTS}")"
[ "${KNOWN_HOSTS_STATE}" = "0:10001:640" ] \
    || fail "${BROKER_KNOWN_HOSTS}: ${KNOWN_HOSTS_STATE}, требуется root:10001 640"
[ "$(stat -c '%u:%g:%a' "$(dirname "${BROKER_KNOWN_HOSTS}")")" = "0:0:755" ] \
    || fail "Каталог pinned known_hosts должен быть root:root 755"
[ "$(grep -cEv '^[[:space:]]*$' "${BROKER_KNOWN_HOSTS}")" -eq 1 ] \
    || fail "${BROKER_KNOWN_HOSTS}: требуется ровно одна запись"
awk 'NF == 3 && $1 == "10.89.0.1" && $2 == "ssh-ed25519" {ok=1} END {exit !ok}' \
    "${BROKER_KNOWN_HOSTS}" \
    || fail "${BROKER_KNOWN_HOSTS}: разрешён только 10.89.0.1 ssh-ed25519"
PINNED_FINGERPRINT="$(ssh-keygen -lf "${BROKER_KNOWN_HOSTS}" -E sha256 | awk 'NR == 1 {print $2}')"
HOST_FINGERPRINT="$(ssh-keygen -lf "${HOST_KEY_PUBLIC}" -E sha256 | awk 'NR == 1 {print $2}')"
[ -n "${PINNED_FINGERPRINT}" ] && [ "${PINNED_FINGERPRINT}" = "${HOST_FINGERPRINT}" ] \
    || fail "Pinned broker host key mismatch; refusing to start Canvas"
ok "Pinned broker known_hosts: root-controlled, exact host fingerprint"

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
