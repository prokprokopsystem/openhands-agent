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

## Двухфазная схема

| Фаза | Конфиг | Назначение |
|---|---|---|
| 1 — Bootstrap | `canvas-bootstrap.conf` | Только HTTP, только ACME — получить сертификат |
| 2 — Final | `canvas.prokop-agent.duckdns.org.conf` | HTTPS + Basic Auth + proxy → Canvas |

## Инструкция

Все команды выполняются на VPS (ssh vps-autolead) от root или через sudo.

---

### Фаза 1 — Bootstrap: получить сертификат Let's Encrypt

#### Шаг 1.1 — Read-only проверки (перед любыми изменениями)

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

# Имя canvas ещё не используется в Nginx
nginx -T 2>/dev/null | grep -c 'canvas.prokop-agent.duckdns.org'
# Ожидается: 0

# Nginx в рабочем состоянии
sudo nginx -t && echo "OK"
# Ожидается: syntax is ok / test is successful / OK
```

#### Шаг 1.2 — Создать ACME webroot

```bash
# Каталог для Let's Encrypt HTTP-челленджа (.well-known/acme-challenge)
sudo mkdir -p /var/www/canvas-acme
sudo chown www-data:www-data /var/www/canvas-acme
sudo chmod 755 /var/www/canvas-acme
```

#### Шаг 1.3 — Установить bootstrap-конфиг

```bash
# Скопировать из репозитория
sudo cp deployment/nginx/canvas-bootstrap.conf \
        /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org

sudo chown root:root /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org
sudo chmod 644 /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org

# Активировать (symlink, не перезаписывает существующие сайты)
sudo ln -s /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org \
           /etc/nginx/sites-enabled/canvas.prokop-agent.duckdns.org
```

#### Шаг 1.4 — Проверить и reload

```bash
# Синтаксическая проверка
sudo nginx -t
# Ожидается: syntax is ok / test is successful

# Только после успешной проверки — reload
sudo systemctl reload nginx

# Проверить статус
sudo systemctl status nginx
# Ожидается: active (running)
```

#### Шаг 1.5 — Получить сертификат (certonly, без изменения конфига)

```bash
# certonly --webroot — не трогает Nginx-конфиг
sudo certbot certonly --webroot \
    -w /var/www/canvas-acme \
    -d canvas.prokop-agent.duckdns.org \
    --non-interactive --agree-tos \
    -m admin@prokop-agent.duckdns.org

# Убедиться, что файлы сертификата существуют (содержимое не выводить)
sudo test -f /etc/letsencrypt/live/canvas.prokop-agent.duckdns.org/fullchain.pem && echo "OK: fullchain"
sudo test -f /etc/letsencrypt/live/canvas.prokop-agent.duckdns.org/privkey.pem   && echo "OK: privkey"
# Ожидается: OK: fullchain / OK: privkey
```

---

### Фаза 2 — Final: HTTPS + Basic Auth + Canvas

#### Шаг 2.1 — Создать htpasswd

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

#### Шаг 2.2 — Заменить bootstrap на окончательный конфиг

```bash
# Перезаписать sites-available окончательным конфигом
sudo cp deployment/nginx/canvas.prokop-agent.duckdns.org.conf \
        /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org

# Права
sudo chown root:root /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org
sudo chmod 644 /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org

# Symlink уже существует с фазы 1 — обновлять не нужно.
```

#### Шаг 2.3 — Проверить и reload

```bash
# Синтаксическая проверка
sudo nginx -t
# Ожидается: syntax is ok / test is successful

# Только после успешной проверки — reload
sudo systemctl reload nginx

# Проверить статус
sudo systemctl status nginx
# Ожидается: active (running)
```

#### Шаг 2.4 — Проверки после развёртывания

```bash
# HTTP → редирект на HTTPS
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://canvas.prokop-agent.duckdns.org/
# Ожидается: 301 https://canvas.prokop-agent.duckdns.org/

# HTTPS 401 при отсутствии авторизации
curl -sS -o /dev/null -w '%{http_code}\n' https://canvas.prokop-agent.duckdns.org/
# Ожидается: 401

# HTTPS с Basic Auth → Canvas
# Пароль запрашивается интерактивно, не попадает в историю shell.
curl -sS -o /dev/null -w '%{http_code}\n' -u igor https://canvas.prokop-agent.duckdns.org/canvas
# При запросе пароля — ввести пароль из htpasswd.
# Ожидается: 200

# / → редирект на /canvas
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' -u igor https://canvas.prokop-agent.duckdns.org/
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

---

## Откат

Только Canvas-сайт, без влияния на другие сайты:

```bash
# Удалить symlink из sites-enabled
sudo rm /etc/nginx/sites-enabled/canvas.prokop-agent.duckdns.org

# Проверить конфиг
sudo nginx -t

# Reload
sudo systemctl reload nginx

# Удалить файлы (опционально):
sudo rm /etc/nginx/sites-available/canvas.prokop-agent.duckdns.org
sudo rm /etc/nginx/.htpasswd-canvas

# Сертификат Let's Encrypt остаётся — удалить при необходимости:
# sudo certbot delete --cert-name canvas.prokop-agent.duckdns.org
```

---

## Команды, которые документированы, но НЕ выполнялись

| Команда | Статус |
|---|---|
| `sudo mkdir -p /var/www/canvas-acme` | Не выполнена |
| `sudo cp ... sites-available/` | Не выполнена |
| `sudo ln -s ... sites-enabled/` | Не выполнена |
| `sudo htpasswd -c ...` | Не выполнена |
| `sudo nginx -t` (на VPS) | Не выполнена |
| `sudo systemctl reload nginx` | Не выполнена |
| `sudo certbot certonly --webroot ...` | Не выполнена |
| Проверки HTTP/HTTPS (шаг 2.4) | Не выполнены |

**Следующий шаг:** ручное применение инструкции (этап 3.3 APPLY).
