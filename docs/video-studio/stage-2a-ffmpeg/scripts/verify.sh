#!/usr/bin/env bash
# Проверка установки: конфигурация, лимиты, бинарники, кодеки, дисковая защита
# и модуль сверки размера.
# Медиа не читает, файлов не создаёт, кодирование не запускает.
set -euo pipefail

ROOT="${ROOT:-/home/igor/video-studio}"
cd "$ROOT"

pass=0
fail=0
ok()  { printf '  ПРОЙДЕНО: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  НЕ ПРОЙДЕНО: %s\n' "$1"; fail=$((fail+1)); }

echo '== 1. Конфигурация Compose =='
docker compose config --quiet && ok 'docker compose config корректен'

echo
echo '== 2. Бинарники в образе =='
docker compose run --rm --no-deps --entrypoint /usr/local/bin/ffmpeg studio -version \
  | head -1 | sed 's/^/  /'
docker compose run --rm --no-deps --entrypoint /usr/local/bin/ffprobe studio -version \
  | head -1 | sed 's/^/  /'
ok 'ffmpeg и ffprobe отвечают'

echo
echo '== 3. Кодеки, фильтры и пользователь =='
docker compose run --rm --no-deps --entrypoint /bin/sh studio -c '
set -e
for e in libx264 aac libmp3lame; do
  /usr/local/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $e " \
    && echo "  ПРОЙДЕНО: кодировщик $e" || { echo "  НЕ ПРОЙДЕНО: кодировщик $e"; exit 1; }
done
for f in concat xfade fade scale overlay amix volume loudnorm atempo setpts fps crop pad; do
  /usr/local/bin/ffmpeg -hide_banner -filters 2>/dev/null | awk "{print \$2}" | grep -qx "$f" \
    && echo "  ПРОЙДЕНО: фильтр $f" || { echo "  НЕ ПРОЙДЕНО: фильтр $f"; exit 1; }
done
echo "  ПРОЙДЕНО: пользователь $(id -u):$(id -g)"
echo "  ПРОЙДЕНО: возможностей $(grep CapEff /proc/self/status | awk "{print \$2}")"
'
pass=$((pass+10))

echo
echo '== 4. Жёсткий предел дискового вывода (tmpfs) =='
docker compose run --rm --no-deps --entrypoint /bin/sh studio -c '
set -e
t=$(stat -f -c %T /out)
[ "$t" = tmpfs ] && echo "  ПРОЙДЕНО: /out это $t" || { echo "  НЕ ПРОЙДЕНО: /out это $t"; exit 1; }
lim=$(df -Pk /out | awk "NR==2{print \$2}")
echo "  ПРОЙДЕНО: размер /out $((lim/1024)) MiB"
[ "$lim" -gt 0 ] && [ "$lim" -le 1048576 ] \
  && echo "  ПРОЙДЕНО: предел не больше 1 GiB" \
  || { echo "  НЕ ПРОЙДЕНО: предел $lim KiB"; exit 1; }
if echo probe > /out/.verify-probe 2>/dev/null; then
  rm -f /out/.verify-probe
  echo "  ПРОЙДЕНО: запись в /out работает"
else
  echo "  НЕ ПРОЙДЕНО: запись в /out не работает"; exit 1
fi
'
pass=$((pass+3))

echo
echo '== 5. Изоляция: отсутствие записи на хост =='
cfg=$(docker compose config --format json)

if printf '%s' "$cfg" | python3 -c '
import json,sys
svc=json.load(sys.stdin)["services"]["studio"]
vols=svc.get("volumes",[])
bad=[v for v in vols if not v.get("read_only") and v.get("type")=="bind"]
print("rw-bind-count=%d" % len(bad))
sys.exit(0 if not bad else 1)
' | grep -q 'rw-bind-count=0'; then
  ok 'нет bind-монтирования с записью'
else
  bad 'есть bind-монтирование с записью на хост'
fi

if printf '%s' "$cfg" | python3 -c '
import json,sys
svc=json.load(sys.stdin)["services"]["studio"]
vols=svc.get("volumes",[])
w=[v for v in vols if v.get("target")=="/work"]
assert w and w[0].get("read_only") is True, w
sys.exit(0)
'; then ok 'вход /work только на чтение'; else bad 'вход /work не защищён'; fi

printf '%s' "$cfg" | grep -q 'docker.sock' && bad 'найден docker.sock' || ok 'docker.sock не смонтирован'
[ "$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["studio"].get("read_only"))')" = "True" ] \
  && ok 'корневая ФС read-only' || bad 'корневая ФС не read-only'
[ "$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["studio"]["network_mode"])')" = "none" ] \
  && ok 'сеть отключена' || bad 'сеть не отключена'

for pair in "mem_limit:2147483648" "memswap_limit:2147483648" "pids_limit:256" "cpus:2"; do
  key=${pair%%:*}; want=${pair##*:}
  got=$(printf '%s' "$cfg" | python3 -c "import json,sys; v=json.load(sys.stdin)['services']['studio'].get('$key'); print(int(float(v)))")
  [ "$got" = "$want" ] && ok "$key = $got" || bad "$key = $got, ожидалось $want"
done

echo
echo '== 6. Ограничитель внутри образа =='
if docker compose run --rm --no-deps --entrypoint /bin/sh studio -c 'test -x /usr/local/bin/ffmpeg-guard'; then
  ok 'entrypoint-ограда в образе на месте'
else
  bad 'ограда в образе отсутствует'
fi

# Ограда сверяет размер хранилища через общий модуль. Без модуля она обязана
# отказать, а не продолжить работу: иначе проверка размера молча исчезнет.
if docker compose run --rm --no-deps --entrypoint /bin/sh studio -c 'test -r /usr/local/bin/size-check.sh'; then
  ok 'модуль сверки размера в образе на месте'
else
  bad 'модуль сверки размера в образе отсутствует'
fi

if docker compose run --rm --no-deps -e SIZE_CHECK_LIB=/usr/local/bin/missing-size-check \
     studio -version >/dev/null 2>&1; then
  bad 'ограда работает без модуля сверки размера'
else
  ok 'без модуля сверки размера ограда отказывает'
fi

if docker compose run --rm --no-deps --entrypoint /bin/sh studio -c '
. /usr/local/bin/size-check.sh
size_matches 42991616 40 && ! size_matches 42992640 40
' 2>/dev/null; then
  ok 'сверка размера: допуск 1 GiB, дальше отказ'
else
  bad 'сверка размера не совпала с допуском 1 GiB'
fi

echo
printf 'ИТОГ: ПРОЙДЕНО %s, НЕ ПРОЙДЕНО %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
