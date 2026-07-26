#!/usr/bin/bash
# OpenHands Agent Canvas — проверка шаблонов Nginx (этап 3.3)
# Только read-only. Не изменяет VPS, не выводит секреты.
# Завершается с exit 1 при ошибке или если nginx -t не выполнялся.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NGINX_DIR="${PROJECT_ROOT}/deployment/nginx"
BOOTSTRAP_CONF="${NGINX_DIR}/canvas-bootstrap.conf"
FINAL_CONF="${NGINX_DIR}/canvas.prokop-agent.duckdns.org.conf"
README="${NGINX_DIR}/README.md"

PASSED=0
FAILED=0
SKIPPED=0

TMP_NGINX=""  # будет создан при необходимости

cleanup() {
    [ -n "${TMP_NGINX}" ] && rm -rf "${TMP_NGINX}" || true
}
trap cleanup EXIT

pass() { printf '  [OK]    %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  [FAIL]  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  [SKIP]  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }

echo "=== Stage 3.3 Nginx template validation ==="
echo ""

# ── 1. Файлы существуют ──
echo "--- Files ---"
[ -f "${FINAL_CONF}" ]     && pass "canvas.prokop-agent.duckdns.org.conf"     || fail "canvas.prokop-agent.duckdns.org.conf отсутствует"
[ -f "${BOOTSTRAP_CONF}" ] && pass "canvas-bootstrap.conf"                    || fail "canvas-bootstrap.conf отсутствует"
[ -f "${README}" ]         && pass "README.md"                                || fail "README.md отсутствует"

# ── 2. Nginx syntax check ──
echo ""
echo "--- Nginx syntax ---"

NGINX_OK=false
if command -v nginx >/dev/null 2>&1; then

    # ── 2a. Bootstrap config (не требует сертификатов) ──
    echo "  Bootstrap config:"
    TMP_NGINX=$(mktemp -d /tmp/nginx-validate-XXXXXX)

    cat > "${TMP_NGINX}/nginx.conf" <<NGX
daemon off;
error_log /dev/null crit;
pid ${TMP_NGINX}/nginx.pid;
events { worker_connections 16; }
http {
    access_log off;
    include ${BOOTSTRAP_CONF};
}
NGX
    if nginx -t -c "${TMP_NGINX}/nginx.conf" -p "${TMP_NGINX}" 2>&1; then
        pass "nginx -t bootstrap (синтаксис корректен)"
    else
        fail "nginx -t bootstrap (ошибка синтаксиса)"
        NGINX_OK=false
    fi

    # ── 2b. Final config (нужны тестовые сертификат и ключ) ──
    echo "  Final config:"

    # Создать временный self-signed сертификат ИСКЛЮЧИТЕЛЬНО для проверки синтаксиса
    TEST_CERT_DIR="${TMP_NGINX}/certs"
    mkdir -p "${TEST_CERT_DIR}"

    openssl req -x509 -nodes -days 1 \
        -newkey rsa:2048 \
        -keyout "${TEST_CERT_DIR}/privkey.pem" \
        -out "${TEST_CERT_DIR}/fullchain.pem" \
        -subj "/CN=canvas.prokop-agent.duckdns.org" \
        2>/dev/null

    # Временная копия конфига с подменёнными путями
    FINAL_TMP="${TMP_NGINX}/final.conf"
    cp "${FINAL_CONF}" "${FINAL_TMP}"
    sed -i "s|/etc/letsencrypt/live/canvas.prokop-agent.duckdns.org|${TEST_CERT_DIR}|g" "${FINAL_TMP}"

    cat > "${TMP_NGINX}/nginx-final.conf" <<NGX
daemon off;
error_log /dev/null crit;
pid ${TMP_NGINX}/nginx-final.pid;
events { worker_connections 16; }
http {
    access_log off;
    include ${FINAL_TMP};
}
NGX
    if nginx -t -c "${TMP_NGINX}/nginx-final.conf" -p "${TMP_NGINX}" 2>&1; then
        pass "nginx -t final (синтаксис корректен)"
        NGINX_OK=true
    else
        fail "nginx -t final (ошибка синтаксиса)"
        NGINX_OK=false
    fi

else
    skip "nginx не установлен локально — синтаксис НЕ проверен"
    NGINX_OK=false
fi

# ── 3. Обязательные директивы (bootstrap) ──
echo ""
echo "--- Bootstrap required directives ---"
BOOTSTRAP_REQUIRED=(
    "listen 80"
    "server_name canvas.prokop-agent.duckdns.org"
    "\.well-known/acme-challenge"
    "/var/www/canvas-acme"
)

for directive in "${BOOTSTRAP_REQUIRED[@]}"; do
    if grep -qE "${directive}" "${BOOTSTRAP_CONF}"; then
        pass "bootstrap: ${directive}"
    else
        fail "bootstrap: ${directive} — не найдено"
    fi
done

# Bootstrap НЕ должен содержать HTTPS/proxy
grep -q 'listen 443' "${BOOTSTRAP_CONF}"  && fail "bootstrap: listen 443 (не должно быть)"  || pass "bootstrap: без listen 443"
grep -q 'proxy_pass' "${BOOTSTRAP_CONF}"  && fail "bootstrap: proxy_pass (не должно быть)"  || pass "bootstrap: без proxy_pass"
grep -q 'auth_basic' "${BOOTSTRAP_CONF}"  && fail "bootstrap: auth_basic (не должно быть)"  || pass "bootstrap: без auth_basic"
grep -q 'ssl_certificate' "${BOOTSTRAP_CONF}" && fail "bootstrap: ssl_certificate (не должно быть)" || pass "bootstrap: без ssl_certificate"

# ── 4. Обязательные директивы (final) ──
echo ""
echo "--- Final required directives ---"
FINAL_REQUIRED=(
    "listen 80"
    "listen 443 ssl http2"
    "server_name canvas.prokop-agent.duckdns.org"
    "proxy_pass http://10.77.0.2:8000"
    "auth_basic"
    "auth_basic_user_file"
    "proxy_set_header Upgrade"
    "proxy_set_header Connection.*upgrade"
    "proxy_http_version 1.1"
    "proxy_buffering off"
    "proxy_read_timeout"
    "proxy_set_header Host"
    "proxy_set_header X-Real-IP"
    "proxy_set_header X-Forwarded-Proto"
    "return 301.*canvas"
    "/etc/letsencrypt/live/canvas.prokop-agent.duckdns.org"
    "fullchain.pem"
    "privkey.pem"
    "\.well-known/acme-challenge"
)

for directive in "${FINAL_REQUIRED[@]}"; do
    if grep -qE "${directive}" "${FINAL_CONF}"; then
        pass "final: ${directive}"
    else
        fail "final: ${directive} — не найдено"
    fi
done

# ── 5. Плейсхолдеры и ошибочные адреса ──
echo ""
echo "--- Placeholders and hardcoded errors ---"
for conf in "${BOOTSTRAP_CONF}" "${FINAL_CONF}"; do
    name=$(basename "${conf}")
    grep -qi 'placeholder' "${conf}" && fail "${name}: placeholder в тексте" || pass "${name}: без placeholder"
    grep -q 'localhost:8000\|127.0.0.1:8000' "${conf}" && fail "${name}: localhost:8000" || pass "${name}: без localhost:8000"
    grep 'proxy_pass' "${conf}" 2>/dev/null | grep -q '0.0.0.0' && fail "${name}: 0.0.0.0 в proxy_pass" || pass "${name}: без 0.0.0.0 в proxy_pass"
done

# ── 6. Секреты ──
echo ""
echo "--- Secrets ---"
for conf in "${BOOTSTRAP_CONF}" "${FINAL_CONF}"; do
    name=$(basename "${conf}")
    grep -qE '\$2[aby]\$[0-9]+\$' "${conf}"                && fail "${name}: bcrypt-хеш"                || pass "${name}: без bcrypt-хешей"
    grep -qE ':[A-Za-z0-9+/=]{20,}' "${conf}"               && fail "${name}: возможный base64-хеш"     || pass "${name}: без base64-хешей"
    grep -qiE 'password\s*[:=]\s*\S' "${conf}"              && fail "${name}: password=..."              || pass "${name}: без открытых паролей"
    grep -qE 'sk-[A-Za-z0-9]{20,}' "${conf}"                && fail "${name}: API-ключ"                 || pass "${name}: без API-ключей"
    grep -qE 'Bearer [A-Za-z0-9]{10,}' "${conf}"            && fail "${name}: Bearer-токен"             || pass "${name}: без Bearer-токенов"
    grep -q 'BEGIN CERTIFICATE\|BEGIN PRIVATE KEY' "${conf}" && fail "${name}: PEM-блок в шаблоне"       || pass "${name}: без PEM-блоков"
done

# ── 7. Сетевая безопасность (final) ──
echo ""
echo "--- Network safety ---"
grep -q 'listen.*8000' "${FINAL_CONF}" && fail "final: listen 8000 (Canvas напрямую)" || pass "final: без listen 8000"
grep -q 'ssl_protocols.*SSLv3\|ssl_protocols.*TLSv1[^.]' "${FINAL_CONF}" && fail "final: устаревшие TLS" || pass "final: без устаревших TLS"

# HTTP → редирект на HTTPS (final)
echo ""
echo "--- HTTP redirect ---"
grep -B2 'return 301 https' "${FINAL_CONF}" | grep -q 'location /' \
    && pass "final: HTTP → HTTPS редирект (location / → 301 https)" \
    || fail "final: нет HTTP → HTTPS редиректа (location / → 301 https)"
grep -q '\.well-known/acme-challenge' "${FINAL_CONF}" && pass "final: ACME challenge в final" || fail "final: нет ACME challenge"

# ── 9. WireGuard endpoint (final) ──
echo ""
echo "--- WireGuard endpoint ---"
grep -q 'proxy_pass http://10.77.0.2:8000' "${FINAL_CONF}" && pass "final: proxy_pass → 10.77.0.2:8000" || fail "final: proxy_pass не 10.77.0.2:8000"

# ── 10. README полнота ──
echo ""
echo "--- README completeness ---"
README_CHECKS=(
    "read-only провер"
    "htpasswd"
    "nginx -t"
    "systemctl reload nginx"
    "certbot"
    "certonly"
    "webroot"
    "Basic Auth"
    "Откат"
    "НЕ выполнялись"
    "bootstrap"
    "canvas-bootstrap"
    "sites-available"
    "sites-enabled"
    "\.well-known"
    "401"
    "Фаза 1"
    "Фаза 2"
    "/var/www/canvas-acme"
)

for check in "${README_CHECKS[@]}"; do
    if grep -qi "${check}" "${README}"; then
        pass "README: ${check}"
    else
        fail "README: ${check} — не найдено"
    fi
done

# ── 11. README: curl без пароля в команде ──
echo ""
echo "--- README: no password in curl ---"
grep -n 'curl.*-u.*:.*https' "${README}" 2>/dev/null \
    && fail "README: пароль в curl-команде (curl -u user:password ...)" \
    || pass "README: curl без пароля в команде"

# ── 12. README: без self-signed ──
echo ""
echo "--- README: no self-signed ---"
grep -qi 'self.sign\|selfsign' "${README}" \
    && fail "README: упоминание self-signed сертификата" \
    || pass "README: без self-signed"

# ── 13. README: без призыва к немедленному выполнению ──
echo ""
echo "--- README: no auto-execute ---"
grep -qiE 'запустите сейчас|выполните сейчас|apply now|run now' "${README}" \
    && fail "README: призыв к немедленному выполнению" \
    || pass "README: без призыва к немедленному выполнению"

# ── 14. Существующая структура не нарушена ──
echo ""
echo "--- Existing structure integrity ---"
EXISTING=(
    "deployment/compose.yaml"
    "deployment/README.md"
    "deployment/systemd/openhands-agent.service"
    "deployment/scripts/prepare.sh"
)
for f in "${EXISTING[@]}"; do
    [ -f "${PROJECT_ROOT}/${f}" ] && pass "${f}" || fail "${f} — отсутствует!"
done

# ── ИТОГ ──
echo ""
echo "=== Итог: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped ==="

if [ "${FAILED}" -gt 0 ]; then
    echo "FATAL: есть ошибки — пакет НЕ готов."
    exit 1
fi

if [ "${SKIPPED}" -gt 0 ]; then
    echo "WARNING: часть проверок пропущена — пакет проверен не полностью (exit 1)."
    exit 1
fi

if ! ${NGINX_OK}; then
    echo "FATAL: nginx -t не выполнялся или завершился с ошибкой — пакет НЕ готов."
    exit 1
fi

echo "All checks passed — пакет готов."
exit 0
