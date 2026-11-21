#!/usr/bin/env python3
"""План чернового монтажа семейного клипа под полный трек 316.108 с.

Отбор — «расчёска со сломанными зубьями»: архив режется на 12 сегментов,
внутри сегмента берутся короткие серии подряд и пропуски по нескольку номеров.
Детерминированно, без дублей. Порядок файлов условный: даты в именах — это
дата экспорта, а не съёмки.

    plan_montage.py inventory.csv plan.csv --target 316.108
"""
import argparse
import csv
import random

SEED = 20261121
SEGMENTS = 12
PHOTO_COUNT = 15
LONG_VIDEO_MOMENTS = 4
XFADE = 0.5
DRAFT_W, DRAFT_H, FPS = 540, 960, 30


def load(path):
    circles, longs, photos = [], [], []
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                dur = float(r["duration"] or 0)
                w, h = int(r["width"] or 0), int(r["height"] or 0)
            except ValueError:
                continue
            if w == 0 or h == 0:
                continue
            if r["kind"] == "image":
                if r["ext"] == "jpg":
                    photos.append({"file": r["file"], "dur": 0.0, "w": w, "h": h, "kind": "photo"})
            elif r["kind"] == "video" and dur > 0.5:
                item = {"file": r["file"], "dur": dur, "w": w, "h": h,
                        "kind": "circle" if w == h else "long"}
                (circles if w == h else longs).append(item)
    for lst in (circles, longs, photos):
        lst.sort(key=lambda x: x["file"])
    return circles, longs, photos


def comb(items, rng, need_per_segment):
    """Серии подряд и пропуски, равномерно по всему сегменту.

    Опорные точки ставятся через равные промежутки, чтобы покрыть сегмент
    целиком; часть точек разворачивается в серию из 2–3 соседних номеров,
    остальные идут одиночными — это и даёт «сломанные зубья» с пропусками.
    """
    if not items:
        return []
    n = max(1, need_per_segment)
    step = len(items) / n
    picked = []
    for k in range(n):
        base = int(k * step + rng.uniform(0, max(0.0, step - 1)))
        base = min(base, len(items) - 1)
        run = rng.choice([1, 1, 2, 2, 3]) if rng.random() < 0.6 else 1
        for j in range(run):
            if base + j < len(items) and base + j not in picked:
                picked.append(base + j)
    return sorted(picked)


def window(item, planned_dur, rng):
    """Режет окно внутри клипа, обходя размытое начало и пустой конец."""
    total = item["dur"]
    want = min(planned_dur, total - 0.4)
    if want < 1.2:
        return None
    latest = max(0.0, total - want - 0.3)
    start = rng.uniform(0.3, 0.3 + latest * 0.55) if latest > 0 else 0.0
    start = min(start, latest)
    return round(start, 3), round(want, 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inventory")
    ap.add_argument("out")
    ap.add_argument("--target", type=float, default=316.108)
    ap.add_argument("--videos", type=int, default=64)
    a = ap.parse_args()

    circles, longs, photos = load(a.inventory)
    rng = random.Random(SEED)

    # Кружки: 12 сегментов, чтобы архив был покрыт равномерно.
    n_circle = a.videos - LONG_VIDEO_MOMENTS
    seg_size = len(circles) / SEGMENTS
    per_seg = max(1, round(n_circle / SEGMENTS))
    chosen_circles = []
    for s in range(SEGMENTS):
        seg = circles[int(s * seg_size): int((s + 1) * seg_size)]
        for k in comb(seg, rng, per_seg):
            chosen_circles.append(seg[k])
    if len(chosen_circles) > n_circle:
        step = len(chosen_circles) / n_circle
        chosen_circles = [chosen_circles[min(int(i * step), len(chosen_circles) - 1)]
                          for i in range(n_circle)]

    # Четыре длинных видео: по одному моменту, распределены по клипу.
    chosen_longs = []
    if longs:
        step = max(1, len(longs) // LONG_VIDEO_MOMENTS)
        for i in range(LONG_VIDEO_MOMENTS):
            chosen_longs.append(longs[min(i * step, len(longs) - 1)])

    # Фотографии: равномерно по всему архиву, а не подряд.
    photos_sorted = photos[:]
    if len(photos_sorted) > PHOTO_COUNT:
        step = len(photos_sorted) / PHOTO_COUNT
        photos_pick = [photos_sorted[min(int(i * step), len(photos_sorted) - 1)]
                       for i in range(PHOTO_COUNT)]
    else:
        photos_pick = photos_sorted

    videos_sel = [{"item": it, "kind": it["kind"], "dur_plan": round(rng.uniform(3.0, 4.6), 2)}
                  for it in (chosen_circles + chosen_longs)]
    # Часть планов длиннее — спокойные 5–6 с, редкие акценты по 2 с.
    for k in rng.sample(range(len(videos_sel)), max(1, len(videos_sel) // 8)):
        videos_sel[k]["dur_plan"] = 2.0
    for k in rng.sample(range(len(videos_sel)), max(1, len(videos_sel) // 6)):
        videos_sel[k]["dur_plan"] = round(rng.uniform(5.0, 6.0), 2)

    photos_sel = [{"item": it, "kind": "photo", "dur_plan": round(rng.uniform(6.0, 8.0), 2)}
                  for it in photos_pick]

    # Порядок: видеоряд в порядке архива, фото вклиниваются равномерно.
    seq = videos_sel[:]
    gap = max(1, len(seq) // max(1, len(photos_sel)))
    for n, ph in enumerate(photos_sel):
        seq.insert(min(len(seq), (n + 1) * gap + n), ph)

    # Фактические окна и длительности.
    rows = []
    for e in seq:
        if e["kind"] == "photo":
            rows.append({"file": e["item"]["file"], "kind": "photo", "start": 0.0,
                         "dur": e["dur_plan"], "w": e["item"]["w"], "h": e["item"]["h"],
                         "xfade": round(rng.choice([0.5, 0.5, 0.6, 0.45]), 2)})
            continue
        w = window(e["item"], e["dur_plan"], rng)
        if w is None:
            continue
        rows.append({"file": e["item"]["file"], "kind": e["kind"], "start": w[0],
                     "dur": w[1], "w": e["item"]["w"], "h": e["item"]["h"],
                     "xfade": round(rng.choice([0.5, 0.5, 0.6, 0.4, 0.0, 0.0]), 2)})

    # Переход не может быть длиннее половины короткого соседа.
    for i, r in enumerate(rows):
        limit = min(r["dur"], rows[max(0, i - 1)]["dur"] if i else r["dur"]) * 0.5
        r["xfade"] = min(r["xfade"], round(limit, 2)) if r["xfade"] else 0.0

    # Подгонка длительности: масштабируем планы, затем правим хвост.
    def total(rs):
        return sum(x["dur"] for x in rs) - sum(x["xfade"] for x in rs)

    k = a.target / total(rows)
    for r in rows:
        r["dur"] = round(r["dur"] * k, 3)
    delta = round(a.target - total(rows), 3)
    rows[-1]["dur"] = round(rows[-1]["dur"] + delta, 3)

    with open(a.out, "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=["idx", "file", "kind", "start", "dur", "w", "h", "xfade"])
        wr.writeheader()
        for n, r in enumerate(rows):
            wr.writerow({"idx": n, **r})

    vids = sum(1 for r in rows if r["kind"] != "photo")
    phs = sum(1 for r in rows if r["kind"] == "photo")
    print(f"клипов: {len(rows)} (видео {vids}, фото {phs})")
    print(f"сумма планов: {sum(r['dur'] for r in rows):.3f} с, "
          f"перекрытия: {sum(r['xfade'] for r in rows):.3f} с, "
          f"ИТОГО: {total(rows):.3f} с (цель {a.target})")
    print(f"видео: среднее {sum(r['dur'] for r in rows if r['kind'] != 'photo') / max(1, vids):.2f} с, "
          f"мин {min(r['dur'] for r in rows if r['kind'] != 'photo'):.2f}, "
          f"макс {max(r['dur'] for r in rows if r['kind'] != 'photo'):.2f}")
    print(f"фото: среднее {sum(r['dur'] for r in rows if r['kind'] == 'photo') / max(1, phs):.2f} с")
    print(f"жёстких склеек: {sum(1 for r in rows if not r['xfade'])}")


if __name__ == "__main__":
    main()
