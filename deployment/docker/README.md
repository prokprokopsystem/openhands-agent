# Производный образ OpenHands Canvas с постоянными PDF-инструментами

Раздел посвящён этапу DEC-026: постоянный набор чтения/обработки/создания PDF в производном
образе от фактически работающего `openhands-agent-canvas-ssh:1.6.1-restored`. См. также
`deployment/README.md`, раздел «Постоянные PDF-инструменты и совместная проверка QET/PDF».

## Что добавляется

- Системные пакеты (Debian 13, зафиксированные версии):
  - `poppler-utils` 25.03.0-5+deb13u2 — pdfinfo, pdftotext, pdftoppm/pdftocairo, pdfimages;
  - `qpdf` 12.2.0-1 — структурная проверка и операции с PDF;
  - `tesseract-ocr` 5.5.0-1+b1 + `tesseract-ocr-eng/pol/rus` 1:4.1.0-2 — OCR;
  - `fonts-dejavu-core` 2.37-8, `fonts-noto-core` 20201225-2 — кириллица и польские диакритики.
- Изолированное Python-окружение `/opt/pdf-tools/venv` (не подменяет системный `python3`,
  не попадает в PATH backend):
  - `PyMuPDF` 1.26.4 — рендер страниц/фрагментов, текст с координатами, изображения;
  - `pypdf` 6.21.2 — страницы, объединение/разделение/поворот, метаданные, формы;
  - `reportlab` 5.1.0 — создание PDF (со шрифтами DejaVu для кириллицы/польского).

Вызов Python-инструментов: `/opt/pdf-tools/venv/bin/python` (например,
`/opt/pdf-tools/venv/bin/python -c "import pymupdf"`). Системный `python3` не изменяется.

## База и совместимость

- База — работающий образ `openhands-agent-canvas-ssh:1.6.1-restored`
  (ID `sha256:293042314e9e535e63c2c65f8df591e3eb545c5d781e402efb799b8a2a5d5a21`).
  До сборки сверить с текущим контейнером: `docker inspect -f '{{.Image}}' openhands-agent`.
- Версии Canvas/SDK, модель и профиль не меняются. ENTRYPOINT/CMD/WORKDIR/USER наследуются.
- Build context содержит только `Dockerfile.pdf-tools`; config, gh, secrets и проекты в образ не попадают.

## Сборка (без sudo, docker-группа)

```bash
mkdir -p /srv/openhands-agent/build-pdf-tools
cp deployment/docker/Dockerfile.pdf-tools /srv/openhands-agent/build-pdf-tools/
cd /srv/openhands-agent/build-pdf-tools
docker build -f Dockerfile.pdf-tools -t openhands-agent-canvas-ssh:1.6.1-restored-pdftools .
docker image inspect openhands-agent-canvas-ssh:1.6.1-restored-pdftools --format '{{.Id}}'
```

Сборку можно выполнять при работающем Canvas: она не трогает действующий контейнер.

## Функциональная проверка (одноразовый контейнер)

```bash
docker run --rm --entrypoint bash openhands-agent-canvas-ssh:1.6.1-restored-pdftools -c '
  set -e
  T=$(mktemp -d); cd "$T"
  # двухстраничный PDF с кириллицей/польским через reportlab + DejaVu
  /opt/pdf-tools/venv/bin/python - <<PY
import pymupdf
d=pymupdf.open(); 
for t in ["Отчёт P04 — тест ąćęłńóśźż","Страница 2 — Y1"]:
    p=d.new_page(); p.insert_text((72,100), t, fontfile="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", fontsize=16)
d.save("t.pdf")
PY
  pdftotext t.pdf - | head -4
  pdftoppm -r 80 -png -f 1 -l 1 t.pdf page
  pdfimages -list t.pdf
  qpdf --check t.pdf
  /opt/pdf-tools/venv/bin/python -c "import pypdf;r=pypdf.PdfReader(\"t.pdf\");r.pages[0].rotate(90);w=pypdf.PdfWriter();w.add_page(r.pages[0]);w.write(\"r.pdf\")"
  qpdf --check r.pdf
  printf \"OCR test\" | tesseract stdin stdout
'
```

Успешный `import` или `--version` не считается функциональной проверкой: критерий — реальный
рендер, извлечённый текст, OCR и проходящий `qpdf --check`.

## Применение и откат (нужен root — одна команда владельцу)

Скрипт `deployment/docker/switch-pdf-image.sh` (на хосте — `/srv/openhands-agent/build-pdf-tools/switch-pdf-image.sh`):

```bash
sudo bash /srv/openhands-agent/build-pdf-tools/switch-pdf-image.sh
```

Скрипт: делает бэкап `compose.yaml`, меняет только строку `image:`, проверяет compose,
перезапускает только `openhands-agent.service`, ждёт `healthy` до ~5 минут; при неуспехе
автоматически возвращает бэкап и перезапускает прежний образ.

Ручной откат при необходимости:

```bash
sudo cp /srv/openhands-agent/deployment/compose.yaml.bak-<TS> /srv/openhands-agent/deployment/compose.yaml
sudo systemctl restart openhands-agent.service
```

Другие сервисы (AMNESIA, Nextcloud, Telegram-gateway, firewall, хостовый Docker) не затрагиваются.
Старый образ `openhands-agent-canvas-ssh:1.6.1-restored` не удаляется — он остаётся точкой отката.

## Фактический результат (24 октября 2026)

Статусы разделены: **собрано** и **проверено в одноразовом контейнере** — да; **применено к живому Canvas** — ожидает sudo-перезапуска.

- **Образ собран:** `openhands-agent-canvas-ssh:1.6.1-restored-pdftools`,
  Id `sha256:40b7a43da65f14b5de79959b82544bec1d2cde4fd4535e9f0ed51e820778b188`,
  +2 слоя от базы, все бинарники (`pdfinfo/pdftotext/pdftoppm/pdftocairo/pdfimages/qpdf/tesseract`) и языки tesseract `eng/pol/rus` на месте.
- **Функциональные пробы (пользователь `openhands`, одноразовый контейнер) — ПРОЙДЕНО:** создание 2-страничного PDF с кириллицей/польским (reportlab + DejaVu), `pdftotext`, текст и рендер страницы/фрагмента (PyMuPDF), merge/split/rotate (pypdf), `qpdf --check`, OCR (распознаны `P04 Y1`).
- **Реальный рендер `лист 07.pdf`** тем же образом и визуальное чтение моделью через Canvas — **ПРОЙДЕНО**.
- **Первая цепь Y1 (QET + визуальный PDF + MASTER) — СОВПАДАЕТ.** Доказательства:
  - QET (реальные element UUID + terminal endpoints, восстановленная геометрия): `A1 id8 (CIO 100.00) ↔ X6:1 ↔ Y1`; `Y1 ↔ X6:6 ↔ arrow(e0f9eb9)=0 V`; `A1 COM id29 ↔ arrow(eec4f86)=+24 V`; перемычка X6 только `6↔7↔8↔9↔10`.
  - PDF (рендер фрагментов): `A1 Omron CP2E-N40DT1-D DIGITAL OUTPUTS (DO)`; вывод `100.00` (крайний левый) уходит вниз к `X6:1`; `Y1` = SMC SY3120 `C1 ACTIVE`; `FROM SHEET 04 / X8 +24 V` → COM-шина A1, `0 V` → вниз к X6-6.
  - MASTER (`P04 — MASTER … .xlsx`, вкладка IO): `100.00 | Y1 | CENTER PRODUCT / C1 ACTIVE | A1 DO → X6:1 → Y1`; `X6:1 → Y1 coil +`, возврат `X6:6 → X8/0V`.
  - **Итог:** `A1 DO 100.00 → X6:1 → Y1`, возврат `Y1 → X6:6 → 0 V`; питание COM → +24 V от X8:7.
- **Устаревшие скрытые имена символов:** элемент A1 в QET имеет тип/текст `a1omron.elmt` / `Delta AX-308EA0MA1P` / `Delta_AX3`, но актуально по PDF и MASTER — `Omron CP2E-N40DT1-D`. Скрытые имена не использовать для идентификации аппарата.
- **Применение к Canvas НЕ выполнено** (нужен `systemctl restart` = sudo). Готов `switch-pdf-image.sh`.
