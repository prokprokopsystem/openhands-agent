#!/bin/bash
# Проверить egress-изоляцию OpenHands
# Запускать изнутри контейнера или с хоста.
# Не применяет правил — только проверка.

echo "=== Проверка egress-изоляции ==="

check_url() {
    local desc="$1"
    local url="$2"
    local expect="$3"

    if curl -fsS -o /dev/null -m 5 "${url}" 2>/dev/null; then
        local result="доступен"
    else
        local result="недоступен"
    fi

    if [ "${result}" = "${expect}" ]; then
        echo "  ✅ ${desc}: ${result}"
    else
        echo "  ❌ ${desc}: ${result} (ожидалось: ${expect})"
    fi
}

echo ""
echo "--- Внешний доступ (должен быть) ---"
check_url "HTTPS (google.com)" "https://google.com" "доступен"
check_url "HTTPS (api.openai.com)" "https://api.openai.com" "доступен"

echo ""
echo "--- Внутренние сервисы (НЕ должны быть доступны) ---"
check_url "AMNESIA Bridge (10.77.0.2:8090)" "http://10.77.0.2:8090/health" "недоступен"
check_url "Nextcloud (10.77.0.2:11000)" "http://10.77.0.2:11000/status.php" "недоступен"
check_url "LAN router (192.168.100.1)" "http://192.168.100.1" "недоступен"

echo ""
echo "--- WebUI (должен быть доступен) ---"
check_url "Agent Canvas (10.77.0.2:8000)" "http://10.77.0.2:8000/canvas" "доступен"

echo ""
echo "=== Проверка завершена ==="
