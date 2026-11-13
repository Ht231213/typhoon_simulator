"""从录屏提取开屏音乐，裁掉开头空白，做成可循环的一个文件，并顺便给卡点做分析。

用法：
    python tools/make_music_from_recording.py <.local/music_raw.wav> [输出 wav]

处理：
    1. 找第一个真正的声音（阈值 -75 dBFS），往前留 20 ms 预卷 → 作为 0 秒
    2. 结尾做 0.6 s 等功率交叉淡化（尾巴混入开头），播完接回曲头听不出接缝
    3. 输出 mono 48 kHz / 16 bit（Godot 里 AudioStreamWAV 循环播放）
    4. 打印前 40 秒的瞬态（onset）排名 —— 启动动画拿它卡点
    5. 画一张波形 + 响度图到 .local/shots/music_profile.png，方便肉眼核对裁剪点
"""

from __future__ import annotations

import json
import sys
import wave
from pathlib import Path

import numpy as np

SR = 48000
FADE_SEC = 0.6
PRE_ROLL = 0.02
ONSET_DB = -75.0


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        ch, sw, sr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    if sw != 2:
        raise SystemExit(f"只支持 16 bit wav（当前 {sw * 8} bit）")
    d = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        d = d.reshape(-1, ch).mean(axis=1)
    if sr != SR:
        n = int(round(d.size * SR / sr))
        d = np.interp(np.linspace(0, 1, n, endpoint=False), np.linspace(0, 1, d.size, endpoint=False), d)
    return d


def first_sound(x: np.ndarray) -> int:
    peak = float(np.abs(x).max())
    thr = peak * 10 ** (ONSET_DB / 20.0)
    idx = np.flatnonzero(np.abs(x) > thr)
    if idx.size == 0:
        return 0
    return max(0, int(idx[0]) - int(PRE_ROLL * SR))


def onset_ranking(x: np.ndarray, upto: float = 40.0, win_sec: float = 0.01) -> list[tuple[float, float]]:
    """返回 [(时间, 该 10 ms 窗相对前一窗的 dB 跃升)]，按跃升排序。"""
    win = int(win_sec * SR)
    n = min(x.size // win, int(upto / win_sec))
    rms = np.sqrt((x[: n * win].reshape(n, win) ** 2).mean(axis=1))
    db = 20 * np.log10(np.maximum(rms, 1e-9))
    jump = np.diff(db)
    order = np.argsort(jump)[::-1]
    out = []
    used: list[float] = []
    for i in order:
        t = round((i + 1) * win_sec, 2)
        if jump[i] < 3.0:
            break
        if any(abs(t - u) < 0.25 for u in used):
            continue
        used.append(t)
        out.append((t, round(float(jump[i]), 1)))
        if len(out) >= 12:
            break
    return sorted(out)


def plot(x: np.ndarray, out_png: Path, marks: list[tuple[float, str]]) -> None:
    try:
        from PIL import Image, ImageDraw
    except Exception:
        return
    W, H = 1400, 420
    img = Image.new("RGB", (W, H), (12, 16, 22))
    dr = ImageDraw.Draw(img)

    def tx(t: float) -> int:
        return int(t / (x.size / SR) * (W - 1))

    mid = H // 2
    # 波形
    cols = x.size // W
    for i in range(W):
        seg = x[i * cols : (i + 1) * cols]
        if seg.size == 0:
            continue
        lo, hi = float(seg.min()), float(seg.max())
        dr.line([(i, mid - hi * (H / 2 - 10)), (i, mid - lo * (H / 2 - 10))], fill=(70, 140, 190))

    # 响度包络
    win = int(0.05 * SR)
    n = x.size // win
    rms = np.sqrt((x[: n * win].reshape(n, win) ** 2).mean(axis=1))
    db = 20 * np.log10(np.maximum(rms, 1e-9))
    pts = []
    for i in range(n):
        t = (i + 0.5) * 0.05
        level = np.clip((db[i] + 72.0) / 72.0, 0.0, 1.0)
        pts.append((tx(t), int(H - 10 - level * (H - 30))))
    if len(pts) > 1:
        dr.line(pts, fill=(120, 225, 255), width=2)

    for t, label in marks:
        col = (255, 210, 90) if "起" in label else (255, 120, 120)
        dr.line([(tx(t), 0), (tx(t), H)], fill=col, width=1)
        dr.text((tx(t) + 3, 4), label, fill=col)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_png)
    print(json.dumps({"waveform_png": str(out_png)}, ensure_ascii=False))


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("assets/audio/boot_theme.wav")

    x = read_wav(src)
    start = first_sound(x)
    body = x[start:].copy()

    fade = int(FADE_SEC * SR)
    if body.size > fade * 4:
        ramp = np.linspace(0.0, 1.0, fade)
        head = body[:fade].copy()
        body[-fade:] = body[-fade:] * np.cos(ramp * np.pi / 2) + head * np.sin(ramp * np.pi / 2)

    peak = float(np.abs(body).max())
    if peak > 0.99:
        body *= 0.99 / peak

    pcm = (np.clip(body, -1.0, 1.0) * 32767.0).astype("<i2")
    dst.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

    onsets = onset_ranking(body)
    prof = []
    step = int(0.5 * SR)
    for i in range(0, body.size - step, step):
        seg = body[i : i + step]
        prof.append(round(float(20 * np.log10(max(np.sqrt((seg ** 2).mean()), 1e-9))), 1))

    print(json.dumps({
        "output": str(dst),
        "trim_start_sec": round(start / SR, 3),
        "trimmed_sec": round(start / SR, 3),
        "length_sec": round(body.size / SR, 3),
        "fade_sec": FADE_SEC,
        "peak_dbfs": round(20 * np.log10(max(float(np.abs(body).max()), 1e-9)), 2),
        "onsets_first_40s": onsets,
        "loudness_0p5s_first_60s": prof[:60],
    }, ensure_ascii=False, indent=2))

    plot(body, Path(".local/shots/music_profile.png"),
         [(0.0, "起"), (onsets[0][0] if onsets else 0.0, "最强瞬态")])


if __name__ == "__main__":
    main()
