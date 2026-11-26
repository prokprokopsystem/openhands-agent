#!/usr/bin/env python3
"""Анализ речевой дорожки: сегменты речи/паузы, оценка F0 и признаков голоса."""
import array, math, sys, wave

WAV = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tokyo/golos.wav"
FRAME_MS = 20
HOP_MS = 10

with wave.open(WAV, "rb") as w:
    rate = w.getframerate()
    ch = w.getnchannels()
    sw = w.getsampwidth()
    n = w.getnframes()
    raw = w.readframes(n)

assert sw == 2
samples = array.array("h")
samples.frombytes(raw)
if ch == 2:
    samples = array.array("h", samples[0::2])
del raw

N = len(samples)
dur = N / rate
frame = int(rate * FRAME_MS / 1000)
hop = int(rate * HOP_MS / 1000)
lag_min = int(rate / 400)
lag_max = int(rate / 60)
w_len = int(rate * 0.03)


def frame_stats(start):
    seg = samples[start:start + frame]
    if len(seg) < frame // 2:
        return None
    s = 0
    zc = 0
    prev = seg[0]
    for v in seg:
        s += v * v
        if (v >= 0) != (prev >= 0):
            zc += 1
        prev = v
    rms = math.sqrt(s / len(seg)) / 32768.0
    zcr = zc / len(seg)
    x = seg[:w_len]
    mean = sum(x) / len(x)
    x = [v - mean for v in x]
    e0 = sum(v * v for v in x) or 1.0
    best, bestlag = 0.0, 0
    for lag in range(lag_min, min(lag_max, len(x) // 2)):
        acc = 0.0
        for i in range(0, len(x) - lag):
            acc += x[i] * x[i + lag]
        r = acc / e0
        if r > best:
            best, bestlag = r, lag
    f0 = rate / bestlag if bestlag and best > 0.35 else 0.0
    return rms, zcr, f0, best


rows = []
t = 0
while t + frame <= N:
    st = frame_stats(t)
    if st:
        rms, zcr, f0, conf = st
        rows.append((t / rate, rms, zcr, f0, conf))
    t += hop

db = [20 * math.log10(max(r[1], 1e-6)) for r in rows]
peak = max(db)
thr = max(peak - 22, -48)
speech = [d > thr for d in db]


def fill(flags, gap_frames, value):
    i = 0
    out = flags[:]
    while i < len(out):
        if out[i] != value:
            j = i
            while j < len(out) and out[j] != value:
                j += 1
            if j - i <= gap_frames:
                for k in range(i, j):
                    out[k] = value
            i = j
        else:
            i += 1
    return out


gap_f = int(150 / HOP_MS)
isl_f = int(120 / HOP_MS)
sp = fill(speech, gap_f, True)
sp = fill(sp, isl_f, False)

segs = []
i = 0
while i < len(sp):
    if sp[i]:
        j = i
        while j < len(sp) and sp[j]:
            j += 1
        t0 = rows[i][0]
        t1 = rows[j - 1][0] + FRAME_MS / 1000
        seg_rows = rows[i:j]
        voiced = [r for r in seg_rows if r[3] > 0]
        f0s = sorted(r[3] for r in voiced)
        med_f0 = f0s[len(f0s) // 2] if f0s else 0
        zc = sum(r[2] for r in seg_rows) / len(seg_rows)
        rms_avg = sum(r[1] for r in seg_rows) / len(seg_rows)
        segs.append(dict(t0=t0, t1=t1, dur=t1 - t0, f0=med_f0, zcr=zc,
                         db=20 * math.log10(max(rms_avg, 1e-6)), voiced=len(voiced), frames=len(seg_rows)))
        i = j
    else:
        i += 1

print(f"файл: {WAV}")
print(f"частота {rate} Гц, каналов {ch}, {dur:.3f} с, кадров анализа {len(rows)}")
print(f"пик {peak:.1f} dB, порог речи {thr:.1f} dB")
print()
print(f"{'#':>2} {'начало':>7} {'конец':>7} {'длит':>6} {'F0':>6} {'ZCR':>6} {'dB':>6}")
for k, s in enumerate(segs, 1):
    print(f"{k:2} {s['t0']:7.2f} {s['t1']:7.2f} {s['dur']:6.2f} {s['f0']:6.1f} {s['zcr']:6.3f} {s['db']:6.1f}")

print()
print("паузы >= 0.30 с:")
prev_end = 0.0
for s in segs:
    if s['t0'] - prev_end >= 0.30:
        print(f"   {prev_end:7.2f} .. {s['t0']:7.2f}  ({s['t0'] - prev_end:.2f} с)")
    prev_end = max(prev_end, s['t1'])
if dur - prev_end >= 0.30:
    print(f"   {prev_end:7.2f} .. {dur:7.2f}  ({dur - prev_end:.2f} с)")
print()
tot_speech = sum(s['dur'] for s in segs)
print(f"речь суммарно {tot_speech:.2f} с, паузы {dur - tot_speech:.2f} с, сегментов {len(segs)}")
