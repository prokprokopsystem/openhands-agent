#!/usr/bin/env python3
"""Сборка фильма «Из Токио звоню» v1.

Хронометраж строится от звука: звонок идёт через первые две сцены, диалог
начинается в момент снятия трубки, дальше разговор держится на третьей сцене,
финал — реакция Васи и короткий кадр Токио.
"""
import os
import subprocess
import sys

import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()
D = "/tmp/tokyo"
W = f"{D}/work"
os.makedirs(W, exist_ok=True)

S1 = f"{D}/01_Vasya_prosypaetsya_good.mp4.mp4"
S2 = f"{D}/scena2.mp4"
S3 = f"{D}/scena3 dialog.mp4"
S4 = f"{D}/scena4 Wasja w scoku.mp4"
S5 = f"{D}/scena 5 Final .mp4"
VOICE = f"{D}/golos.wav"
ROOSTER = f"{D}/sfx/rooster_pd.ogg"

# --- монтажный лист -----------------------------------------------------------
S1_LEN = 7.875
S2_LEN = 7.875
S3_SEGS = [(0.00, 7.90), (0.30, 7.40), (0.50, 7.20), (0.80, 7.90),
           (1.00, 7.50), (0.80, 7.00), (2.00, 7.90), (5.32, 7.90)]
S4_IN, S4_OUT = 0.10, 4.70
S5_LEN = 4.00

S2_START = S1_LEN
S3_START = S2_START + S2_LEN          # 15.75 — здесь снята трубка
S3_LEN = sum(b - a for a, b in S3_SEGS)
S4_START = S3_START + S3_LEN
S4_LEN = S4_OUT - S4_IN
S5_START = S4_START + S4_LEN
TOTAL = S5_START + S5_LEN

# --- реплики (VAD по golos.wav) ----------------------------------------------
UTTS = [(0.00, 0.98), (2.17, 2.71), (3.56, 3.99), (5.43, 7.34), (7.95, 8.92),
        (10.24, 11.03), (11.81, 12.36), (13.47, 13.99), (14.79, 18.49), (19.15, 19.60),
        (20.38, 21.08), (21.99, 25.23), (26.24, 26.77), (28.29, 29.44), (30.25, 32.54),
        (33.38, 40.44), (41.04, 41.74), (42.42, 44.38), (45.24, 46.86), (48.43, 50.28),
        (51.37, 53.89)]
VOICE_DUR = 54.71
# Петя — собутыльник в Токио, голос из трубки: средний тон 155-195 Гц.
# Вася — низкий хриплый, 85-110 Гц. Реплики 20-21 — финальный выкрик Пети.
PETYA = {2, 4, 5, 8, 12, 16, 17, 20, 21}
PHONE = ("highpass=f=320,lowpass=f=3400,"
         "acompressor=threshold=-20dB:ratio=2.5:attack=8:release=120,volume=1.45")
GAIN = [12.8, 4.7, 6.3, 2.6, -1.1, 3.6, 1.5, -0.7, 3.6, 14.1,
        10.2, 3.2, 5.4, 5.7, 8.4, 4.6, 4.3, 8.1, 13.3, 7.0, -0.5]
MASTER_DB = 2.2


def run(args):
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0:
        print("КОМАНДА НЕ ВЫПОЛНЕНА:", " ".join(args)[:400])
        print(p.stderr[-3000:])
        sys.exit(1)
    return p


def prep_sfx():
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-ss", "7.15", "-t", "0.75",
         "-i", S1, "-vn", "-ac", "2", "-ar", "48000", f"{W}/ring_elem.wav"])
    run([FF, "-y", "-hide_banner", "-loglevel", "error",
         "-i", f"{W}/ring_elem.wav",
         "-f", "lavfi", "-t", "1.15", "-i", "anullsrc=r=48000:cl=stereo",
         "-filter_complex", "[0:a][1:a]concat=n=2:v=0:a=1[out]",
         "-map", "[out]", f"{W}/ring_pattern.wav"])
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-ss", "2.60", "-t", "1.80",
         "-i", S1, "-vn", "-ac", "2", "-ar", "48000",
         "-af", "highpass=f=60,lowpass=f=1200,volume=-4dB", f"{W}/room.wav"])
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-ss", "3.30", "-t", "1.60",
         "-i", S4, "-vn", "-ac", "2", "-ar", "48000", f"{W}/thud.wav"])
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-ss", "2.00", "-t", "4.20",
         "-i", ROOSTER, "-vn", "-ac", "2", "-ar", "48000",
         "-af", "highpass=f=180,lowpass=f=2000,aecho=0.7:0.4:70:0.25,volume=-19dB",
         f"{W}/rooster.wav"])


def prep_voice():
    gaps, prev = [], 0.0
    for t0, t1 in UTTS:
        gaps.append((prev, t0))
        prev = t1

    chunks = []
    for k, ((g0, g1), (t0, t1)) in enumerate(zip(gaps, UTTS)):
        if t0 > g0:
            chunks.append((g0, t0, False, 0.0))
        chunks.append((t0, t1, k + 1 in PETYA, GAIN[k]))
    if prev < VOICE_DUR:
        chunks.append((prev, VOICE_DUR, False, 0.0))

    parts, graph = [], []
    for k, (a, b, phone, gain) in enumerate(chunks):
        label = f"c{k}"
        graph.append(f"[0:a]atrim={a:.3f}:{b:.3f},asetpts=PTS-STARTPTS,"
                     f"aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
                     f"volume={gain:+.2f}dB"
                     f"{',' + PHONE if phone else ''}[{label}]")
        parts.append(f"[{label}]")
    graph.append("".join(parts) + f"concat=n={len(chunks)}:v=0:a=1[out]")
    run([FF, "-y", "-hide_banner", "-loglevel", "error", "-i", VOICE,
         "-filter_complex", ";".join(graph), "-map", "[out]", f"{W}/dialogue.wav"])


def build_video_graph():
    g = [f"[0:v]trim=0:{S1_LEN},setpts=PTS-STARTPTS,fps=24,"
         f"scale=1280:720:flags=lanczos,setsar=1,format=yuv420p[v0]",
         f"[1:v]trim=0:{S2_LEN},setpts=PTS-STARTPTS,fps=24,"
         f"scale=1280:720:flags=lanczos,setsar=1,format=yuv420p[v1]"]
    splits = "".join(f"[s3{i}]" for i in range(len(S3_SEGS)))
    g.append(f"[2:v]fps=24,split={len(S3_SEGS)}{splits}")
    labels = ["[v0]", "[v1]"]
    for i, (a, b) in enumerate(S3_SEGS):
        g.append(f"[s3{i}]trim={a}:{b},setpts=PTS-STARTPTS,"
                 f"scale=1280:720:flags=lanczos,setsar=1,format=yuv420p[v{2 + i}]")
        labels.append(f"[v{2 + i}]")
    n3 = 2 + len(S3_SEGS)
    g.append(f"[3:v]trim={S4_IN}:{S4_OUT},setpts=PTS-STARTPTS,fps=24,"
             f"scale=1280:720:flags=lanczos,setsar=1,format=yuv420p[v{n3}]")
    labels.append(f"[v{n3}]")
    g.append(f"[4:v]trim=0:{S5_LEN},setpts=PTS-STARTPTS,fps=24,"
             f"scale=1280:720:flags=lanczos,setsar=1,format=yuv420p[v{n3 + 1}]")
    labels.append(f"[v{n3 + 1}]")
    g.append("".join(labels) + f"concat=n={len(labels)}:v=1:a=0[vout]")
    return g


def build_audio_graph():
    g = [f"[5:a]atrim=0:{VOICE_DUR},asetpts=PTS-STARTPTS,"
         f"adelay={int(S3_START * 1000)}|{int(S3_START * 1000)}[voice]"]
    ring_stop = S3_START - 0.10
    g.append("[6:a]atrim=0:60,asetpts=PTS-STARTPTS,volume=+6dB,"
             f"adelay=200|200,atrim=0:{ring_stop:.3f}[ring]")
    g.append(f"[7:a]atrim=0:{S4_START + 0.9:.3f},volume=1.0[room]")
    g.append(f"[8:a]adelay={int(S4_START * 1000)}|{int(S4_START * 1000)},volume=1.0[thud]")
    g.append("[9:a]atrim=0:4.20,asplit=2[r1][r2]")
    g.append("[r1]adelay=2600|2600,volume=1.0[roo1]")
    g.append(f"[r2]adelay={int((S4_START - 34.0) * 1000)}|"
             f"{int((S4_START - 34.0) * 1000)},volume=1.0[roo2]")
    g.append(f"[4:a]atrim=0:{S5_LEN},asetpts=PTS-STARTPTS,"
             f"adelay={int(S5_START * 1000)}|{int(S5_START * 1000)},volume=-4dB[city]")
    g.append("[0:a]atrim=0:7.20,asetpts=PTS-STARTPTS,afade=t=out:st=6.90:d=0.30[room_s1]")
    g.append("[voice][ring][room][thud][roo1][roo2][city][room_s1]"
             "amix=inputs=8:duration=longest:normalize=0,"
             f"volume={MASTER_DB:+.2f}dB,"
             "alimiter=limit=0.75:attack=5:release=50:level=false[aout]")
    return g


def main():
    print("шаг 1: элементы звука")
    prep_sfx()
    print("шаг 2: голос")
    prep_voice()
    print("шаг 3: монтаж")
    graph = build_video_graph() + build_audio_graph()
    cmd = [FF, "-y", "-hide_banner", "-loglevel", "error",
           "-i", S1, "-i", S2, "-i", S3, "-i", S4, "-i", S5,
           "-i", f"{W}/dialogue.wav",
           "-stream_loop", "-1", "-i", f"{W}/ring_pattern.wav",
           "-stream_loop", "-1", "-i", f"{W}/room.wav",
           "-i", f"{W}/thud.wav",
           "-i", f"{W}/rooster.wav",
           "-filter_complex", ";".join(graph),
           "-map", "[vout]", "-map", "[aout]",
           "-c:v", "libx264", "-preset", "slow", "-crf", "18",
           "-pix_fmt", "yuv420p", "-r", "24", "-g", "48",
           "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
           "-movflags", "+faststart",
           "-t", f"{TOTAL:.3f}",
           f"{W}/v1.mp4"]
    print(f"сцена 1 0.000-{S1_LEN:.3f}, сцена 2 {S2_START:.3f}-{S3_START:.3f}, "
          f"сцена 3 {S3_START:.3f}-{S4_START:.3f}, сцена 4 {S4_START:.3f}-"
          f"{S5_START:.3f}, Токио {S5_START:.3f}-{TOTAL:.3f}")
    run(cmd)
    print("готово:", f"{W}/v1.mp4")


if __name__ == "__main__":
    main()
