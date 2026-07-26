# Canvas Nginx — ручное развёртывание (этап 3.3)

**Статус:** пакет подготовлен, но НЕ применён. Production не изменялся.

## Маршрут

```
Компьютер Игоря → HTTPS (VPS:443) → Nginx Basic Auth → WireGuard (10.77.0.2:8000) → Agent Canvas
```

## Предварительные условия

- VPS: 95.217.239.148, Nginx 1.24.0, certbot установлен
- WireGuard: VPS (10.77.0.1) ↔ mini-server (10.77.0.2) работает
- Домен `canvas.prokop-agent.duckdns.org` резолвится на VPS
- Существующие Nginx-сайты (`amnesia`, `nextcloud`, `default`) не трогать

## Инструкция

Все команды выполняются на VPS (ssh vps-autolead) от root или через sudo.

### Шаг 1 — Read-only проверки (перед любыми изменениями)

```bash
# Доступность Canvas через WireGuard
curl -sS -o /dev/null -w '%{http_code}\n' http://10.77.0.2:8000/canvas
# Ожидается: 200

# Резолв домена
dig +short canvas.prokop-agent.duckdns.org
# Ожидается: публичный IP VPS

# Существующие сайты (не должны быть затронуты)
ls /etc/nginx/sites-enabled/
# Ожидается: amnesia.prokop-agent.duckdns.org default nextcloud

# Свободен ли порт 443 для нового server_name
nginx -T 2>/dev/null | grep -c 'canvas.prokop-agent.duckdns.org'
# Ожидается: 0 (имя ещё не используется)

# Nginx в рабочем состоянии
nginx -t && echo "OK"
# Ожидается: syntax is ok / test is successful / OK
```

### Шаг 2 — Файл htpasswd (Basic Auth)

```bash
# Установить apache2-utils (если нет)
sudo apt install -y apache2-utils

# Создать файл со скрытым вводом пароля.
# Пароль не записывается в историю команд, не выводится на экран.
sudo htpasswd -c /etc/nginx/.htpasswd-canvas igor
# При запросе «New password» — ввести пароль.
# При запросе «Re-type new password» — повторить пароль.

# Права
sudo chown root:root /etc/nginx/.htpasswd-canvas
sudo chmod 640 /etc/nginx/.htpasswd-canvas
```

### Шаг 3 — Установка Nginx-сайта

```bash
# Копировать конфиг из репозитория в sites-available
sudo cp deployment/nginx/canvas.prokop-agent.duckdns.org.conf \
        /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org

# Владелец и права
sudo chown root:root /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org
sudo chmod 644 /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org

# Активировать сайт (symlink, не перезаписывает существующие)
sudo ln -s /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org \
           /etc/nginx/sites-enabled/canvas.prokop-agent.duckdns.org
```

### Шаг 4 — Проверка до применения

```bash
# Синтаксическая проверка
sudo nginx -t
# Ожидается: syntax is ok / test is successful

# Проверить, что новые директивы не конфликтуют с существующими
sudo nginx -T 2>/dev/null | grep -A2 'server_name canvas'
# Должен показать новый server-блок без ошибок
```

### Шаг 5 — Временный self-signed сертификат (для первого reload до certbot)

```bash
# Создать каталог для временных сертификатов
sudo mkdir -p /etc/nginx/ssl

# Self-signed сертификат (только для прохождения первого nginx reload)
sudo openssl req -x509 -nodes -days 1 \
    -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/canvas-selfsigned.key \
    -out /etc/nginx/ssl/canvas-selfsigned.crt \
    -subj "/CN=canvas.prokop-agent.duckdns.org"

sudo chmod 600 /etc/nginx/ssl/canvas-selfsigned.key
sudo chmod 644 /etc/nginx/ssl/canvas-selfsigned.crt

# Раскомментировать SSL-строки в конфиге:
# В файле /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org
# убрать «# » перед строками:
#   ssl_certificate     /etc/nginx/ssl/canvas-selfsigned.crt;
#   ssl_certificate_key /etc/nginx/ssl/canvas-selfsigned.key;
```

### Шаг 6 — Reload Nginx

```bash
# Повторная проверка (после правок)
sudo nginx -t

# Только после успешной проверки — reload
sudo systemctl reload nginx

# Проверить статус
sudo systemctl status nginx
# Ожидается: active (running)
```

### Шаг 7 — Получение Let's Encrypt сертификата

```bash
# Nginx уже настроен на обслуживание .well-known/acme-challenge
# (см. конфиг: HTTP-блок location /.well-known/acme-challenge/)

# Запустить certbot только для нового домена
sudo certbot --nginx -d canvas.prokop-agent.duckdns.org

# Certbot заменит временный self-signed на реальный сертификат
# и добавит свои директивы в server-блок.

# После certbot — проверить конфиг
sudo nginx -t && sudo systemctl reload nginx
```

### Шаг 8 — Проверки после развёртывания

```bash
# HTTP → редирект на HTTPS
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://canvas.prokop-agent.duckdns.org/
# Ожидается: 301 https://canvas.prokop-agent.duckdns.org/

# HTTPS 401 при отсутствии авторизации
curl -sS -o /dev/null -w '%{http_code}\n' https://canvas.prokop-agent.duckdns.org/
# Ожидается: 401

# HTTPS с Basic Auth → Canvas
curl -sS -o /dev/null -w '%{http_code}\n' -u igor:ПАРОЛЬ https://canvas.prokop-agent.duckdns.org/canvas
# Ожидается: 200

# / → редирект на /canvas
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' -u igor:ПАРОЛЬ https://canvas.prokop-agent.duckdns.org/
# Ожидается: 301 /canvas

# Прямой порт 8000 НЕ доступен из интернета
curl -sS --connect-timeout 5 -o /dev/null -w '%{http_code}\n' http://canvas.prokop-agent.duckdns.org:8000/canvas
# Ожидается: 000 (connection refused/timeout)

# Сертификат валиден
echo | openssl s_client -servername canvas.prokop-agent.duckdns.org \
    -connect canvas.prokop-agent.duckdns.org:443 2>/dev/null \
    | openssl x509 -noout -dates -subject
# Ожидается: subject=CN=canvas.prokop-agent.duckdns.org, даты актуальны
```

### Шаг 9 — Очистка временного self-signed

```bash
# После успешного получения сертификата Let's Encrypt
# временный self-signed больше не нужен:
sudo rm /etc/nginx/ssl/canvas-selfsigned.crt /etc/nginx/ssl/canvas-selfsigned.key
# (каталог /etc/nginx/ssl можно оставить для будущих нужд)
```

## Откат

Откат только Canvas-сайта, без влияния на другие сайты:

```bash
# Удалить symlink из sites-enabled
sudo rm /etc/nginx/sites-enabled/canvas.prokop-agent.duckdns.org

# Проверить конфиг
sudo nginx -t

# Reload
sudo systemctl reload nginx

# Файл конфига в sites-available можно удалить позже:
sudo rm /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org

# Файл паролей (опционально):
sudo rm /etc/nginx/.htpasswd-canvas

# Сертификат Let's Encrypt остаётся — удалить при необходимости:
# sudo certbot delete --cert-name canvas.prokop-agent.duckdns.org
```

## Команды, которые документированы, но НЕ выполнялись

| Команда | Статус |
|---|---|
| `sudo cp ... sites-available/` | Не выполнена (production не тронут) |
| `sudo ln -s ... sites-enabled/` | Не выполнена |
| `sudo htpasswd -c ...` | Не выполнена |
| `sudo openssl req -x509 ...` | Не выполнена |
| `sudo nginx -t` (на VPS) | Не выполнена |
| `sudo systemctl reload nginx` | Не выполнена |
| `sudo certbot --nginx -d ...` | Не выполнена |
| Проверки HTTP/HTTPS (шаг 8) | Не выполнены |

**Следующий шаг:** ручное применение инструкции (этап 3.3 APPLY).
