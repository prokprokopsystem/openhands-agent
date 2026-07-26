#!/usr/bin/bash
# OpenHands Agent Canvas — проверка шаблона Nginx (этап 3.3)
# Только read-only. Не изменяет VPS, не выводит секреты.
# Завершается с exit 1 при ошибке.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NGINX_DIR="${PROJECT_ROOT}/deployment/nginx"
CONF="${NGINX_DIR}/canvas.prokop-agent.duckdns.org.conf"
PASSED=0
FAILED=0

pass() { printf '  [OK] %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAILED=$((FAILED + 1)); }

echo "=== Stage 3.3 Nginx template validation ==="
echo ""

# ── 1. Файлы существуют ──
echo "--- Files ---"
[ -f "${CONF}" ] && pass "canvas.prokop-agent.duckdns.org.conf" || fail "canvas.prokop-agent.duckdns.org.conf отсутствует"
[ -f "${NGINX_DIR}/README.md" ] && pass "README.md" || fail "README.md отсутствует"

# ── 2. Nginx syntax check (локальный) ──
echo ""
echo "--- Nginx syntax ---"
if command -v nginx >/dev/null 2>&1; then
    # Проверить синтаксис через nginx -t с флагом -c
    # Создать временный include-конфиг для изоляции
    TMP_NGINX=$(mktemp -d /tmp/nginx-validate-XXXXXX)
    trap "rm -rf ${TMP_NGINX}" EXIT

    cat > "${TMP_NGINX}/nginx.conf" <<NGX
daemon off;
error_log /dev/null crit;
pid ${TMP_NGINX}/nginx.pid;
events { worker_connections 16; }
http {
    access_log off;
    include ${CONF};
}
NGX
    if nginx -t -c "${TMP_NGINX}/nginx.conf" -p "${TMP_NGINX}" 2>/dev/null; then
        pass "nginx -t (синтаксис корректен)"
    else
        fail "nginx -t (ошибка синтаксиса)"
        nginx -t -c "${TMP_NGINX}/nginx.conf" -p "${TMP_NGINX}" 2>&1 || true
    fi
else
    echo "  [SKIP] nginx не установлен локально"
fi

# ── 3. Обязательные директивы ──
echo ""
echo "--- Required directives ---"
REQUIRED=(
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
)

for directive in "${REQUIRED[@]}"; do
    if grep -qE "${directive}" "${CONF}"; then
        pass "directive: ${directive}"
    else
        fail "directive: ${directive} — не найдено"
    fi
done

# ── 4. Плейсхолдеры и ошибочные адреса ──
echo ""
echo "--- Placeholders and hardcoded errors ---"
# Не должно быть HOSTNAME_PLACEHOLDER
grep -q 'HOSTNAME_PLACEHOLDER' "${CONF}" && fail "HOSTNAME_PLACEHOLDER" || pass "HOSTNAME_PLACEHOLDER отсутствует"

# Не должно быть PLACEHOLDER в рабочей части
# (PLACEHOLDER_START/END в комментариях — допустимо)
WORKING=$(sed '/PLACEHOLDER_START/,/PLACEHOLDER_END/d' "${CONF}")
echo "${WORKING}" | grep -qi 'placeholder' && fail "placeholder в рабочей части" || pass "placeholder отсутствует в рабочей части"

# Не должно быть localhost:8000 (ошибочный прокси)
grep -q 'localhost:8000\|127.0.0.1:8000' "${CONF}" && fail "localhost:8000 (должен быть 10.77.0.2:8000)" || pass "Нет localhost:8000"

# Не должно быть 0.0.0.0 в proxy_pass
grep 'proxy_pass' "${CONF}" | grep -q '0.0.0.0' && fail "0.0.0.0 в proxy_pass" || pass "Нет 0.0.0.0 в proxy_pass"

# ── 5. Секреты ──
echo ""
echo "--- Secrets ---"
# Пароли/хеши htpasswd
grep -qE '\$2[aby]\$[0-9]+\$' "${CONF}" && fail "Найден bcrypt-хеш в шаблоне" || pass "Нет bcrypt-хешей"
grep -qE ':[A-Za-z0-9+/=]{20,}' "${CONF}" && fail "Возможный base64-хеш" || pass "Нет base64-хешей"

# Пароли в открытом виде (password=...)
grep -qiE 'password\s*[:=]\s*\S' "${CONF}" && fail "password=... в открытом виде" || pass "Нет открытых паролей"

# API-ключи
grep -qE 'sk-[A-Za-z0-9]{20,}' "${CONF}" && fail "API-ключ (sk-...)" || pass "Нет API-ключей"
grep -qE 'Bearer [A-Za-z0-9]{10,}' "${CONF}" && fail "Bearer-токен" || pass "Нет Bearer-токенов"

# Сертификаты (не должно быть PEM-блоков)
grep -q 'BEGIN CERTIFICATE\|BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY' "${CONF}" && fail "PEM-блок в шаблоне" || pass "Нет PEM-блоков"

# ── 6. Сетевая безопасность ──
echo ""
echo "--- Network safety ---"
# Canvas не опубликован напрямую (нет listen 8000)
grep -q 'listen.*8000' "${CONF}" && fail "listen 8000 (Canvas не должен быть напрямую)" || pass "Нет listen 8000 (Canvas за прокси)"

# TLS не отключён
grep -q 'ssl_protocols.*SSLv3\|ssl_protocols.*TLSv1[^.]' "${CONF}" && fail "Устаревшие TLS-протоколы" || pass "Нет устаревших TLS-протоколов"

# ── 7. HTTP → HTTPS редирект ──
echo ""
echo "--- HTTP redirect ---"
grep -A10 'listen 80' "${CONF}" | grep -q 'return 301 https' && pass "HTTP → HTTPS редирект" || fail "HTTP → HTTPS редирект не найден"
grep -q '\.well-known/acme-challenge' "${CONF}" && pass "ACME challenge path" || fail "ACME challenge path не найден"

# ── 8. WireGuard endpoint ──
echo ""
echo "--- WireGuard endpoint ---"
grep -q 'proxy_pass http://10.77.0.2:8000' "${CONF}" && pass "proxy_pass → 10.77.0.2:8000" || fail "proxy_pass должен быть http://10.77.0.2:8000"

# ── 9. README полнота ──
echo ""
echo "--- README completeness ---"
README="${NGINX_DIR}/README.md"
[ -f "${README}" ] || { fail "README.md отсутствует"; exit 1; }

README_CHECKS=(
    "read-only провер"
    "htpasswd"
    "nginx -t"
    "systemctl reload nginx"
    "certbot"
    "Basic Auth"
    "Откат"
    "НЕ выполнялись"
    "selfsigned"
    "sites-available"
    "sites-enabled"
    "\.well-known"
    "401"
)

for check in "${README_CHECKS[@]}"; do
    if grep -qi "${check}" "${README}"; then
        pass "README: ${check}"
    else
        fail "README: ${check} — не найдено"
    fi
done

# ── 10. Инструкция не содержит выполняемых команд ──
echo ""
echo "--- README: no auto-execute ---"
# Код-блоки есть, но нет призыва «запусти сейчас»
grep -qiE 'запустите сейчас|выполните сейчас|apply now|run now' "${README}" \
    && fail "README: призыв к немедленному выполнению" \
    || pass "README: без призыва к немедленному выполнению"

# ── 11. Существующая структура deployment/ не нарушена ──
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

echo ""
echo "=== Результат: ${PASSED} passed, ${FAILED} failed ==="
[ "${FAILED}" -eq 0 ] || exit 1
