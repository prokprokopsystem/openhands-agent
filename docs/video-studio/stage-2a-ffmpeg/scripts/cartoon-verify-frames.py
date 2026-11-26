#!/usr/bin/env python3
"""Проверка соответствия кадров фильма исходным сценам (SSIM)."""
import os
import re
import subprocess

import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()
D = "/tmp/tokyo"
W = f"{D}/work"
T = f"{W}/check"
os.makedirs(T, exist_ok=True)

S = {"s1": f"{D}/01_Vasya_prosypaetsya_good.mp4.mp4",
     "s2": f"{D}/scena2.mp4",
     "s3": f"{D}/scena3 dialog.mp4",
     "s4": f"{D}/scena4 Wasja w scoku.mp4",
     "s5": f"{D}/scena 5 Final .mp4"}

# (время в фильме, ожидаемая сцена, время в сцене)
CASES = [(3.00, "s1", 3.00), (11.00, "s2", 3.125),
         (20.00, "s3", 4.25), (27.00, "s3", 3.65), (35.00, "s3", 4.75),
         (45.00, "s3", 1.45), (55.00, "s3", 4.75), (62.00, "s3", 6.75),
         (64.50, "s3", 6.67), (68.00, "s4", 2.37), (72.00, "s5", 1.67)]


def grab(src, t, out):
    subprocess.run([FF, "-y", "-hide_banner", "-loglevel", "error", "-ss", f"{t:.3f}",
                    "-i", src, "-frames:v", "1", "-vf", "scale=1280:720", out],
                   check=True)


def ssim(a, b):
    p = subprocess.run([FF, "-hide_banner", "-i", a, "-i", b, "-lavfi",
                        "ssim=stats_file=-", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.findall(r"All:([0-9.]+)", p.stdout + p.stderr)
    return float(m[0]) if m else -1.0


print(f"{'фильм':>7} {'ожид.':>5} {'кадр':>6}  SSIM с ожидаемой сценой")
for t, key, st in CASES:
    f_out = f"{T}/film_{t:05.2f}.png"
    grab(f"{W}/v1.mp4", t, f_out)
    best = {}
    for k, src in S.items():
        f_src = f"{T}/src_{k}_{st:05.2f}.png"
        grab(src, st, f_src)
        best[k] = ssim(f_out, f_src)
    winner = max(best, key=best.get)
    ok = "OK" if winner == key else "РАСХОЖДЕНИЕ"
    detail = " ".join(f"{k}:{v:.3f}" for k, v in best.items())
    print(f"{t:7.2f} {key:>5} {st:6.2f}  {winner} {ok}  | {detail}")
