"""从录屏里提取开屏音乐，切成一个完整循环。

用法：python tools/extract_boot_music.py <输入 wav> <输出 wav>

做的事：
1. 找开头空白（相对峰值 -45 dB 以下的连续段），裁掉，并留 20 ms 预卷防爆音
2. 用归一化互相关找到「音乐再次回到开头」的位置 = 一个完整循环的终点，
   同时把终点前那一小段循环间隙（如果存在）一起去掉
3. 末尾做 40 ms 等功率交叉淡化，保证播完接回开头听不出缝
4. 打印能量包络里最明显的几个跃升点，给启动动画卡点用

输出是单声道 48 kHz / 16 bit（Godot 里用 AudioStreamWAV 循环播放）。
"""

from __future__ import annotations

import json
import sys
import wave
from pathlib import Path

import numpy as np

SR = 48000


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        ch = w.getnchannels()
        sw = w.getsampwidth()
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    if sw != 2:
        raise SystemExit(f"只支持 16 bit wav，当前 {sw*8} bit")
    data = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        data = data.reshape(-1, ch).mean(axis=1)
    if sr != SR:
        # 简易线性重采样（源是 44.1k/48k，比例不大，够用）
        n = int(round(data.size * SR / sr))
        x_old = np.linspace(0.0, 1.0, data.size, endpoint=False)
        x_new = np.linspace(0.0, 1.0, n, endpoint=False)
        data = np.interp(x_new, x_old, data)
    return data


def rms_envelope(x: np.ndarray, win: int = 480) -> tuple[np.ndarray, np.ndarray]:
    n = x.size // win
    frames = x[: n * win].reshape(n, win)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    times = (np.arange(n) + 0.5) * win / SR
    return times, rms


def find_start(x: np.ndarray, db_floor: float = -45.0) -> int:
    peak = np.abs(x).max()
    thr = peak * 10 ** (db_floor / 20.0)
    idx = np.flatnonzero(np.abs(x) > thr)
    if idx.size == 0:
        return 0
    return max(0, int(idx[0]) - int(0.02 * SR))


def ncc(x: np.ndarray, tpl: np.ndarray, search_from: int) -> np.ndarray:
    """归一化互相关：返回 x[search_from:] 上每个位置与 tpl 的相似度（-1..1）。"""
    m = tpl.size
    seg = x[search_from:]
    n = seg.size
    # 分子：相关（用 FFT）
    size = 1 << int(np.ceil(np.log2(n + m)))
    fx = np.fft.rfft(seg, size)
    ft = np.fft.rfft(tpl[::-1], size)
    num = np.fft.irfft(fx * ft, size)[m - 1 : m - 1 + (n - m + 1)]
    # 分母：滑窗能量
    csum = np.concatenate([[0.0], np.cumsum(seg ** 2)])
    energy = csum[m:] - csum[:-m]
    energy = energy[: num.size]
    denom = np.sqrt(np.maximum(energy, 1e-12) * float((tpl ** 2).sum()))
    return num / denom


def find_loop_end(x: np.ndarray, start: int, min_loop: float = 8.0, max_loop: float = 120.0) -> tuple[int, float]:
    """返回 (循环终点样本, 相似度)。"""
    tpl_len = int(1.2 * SR)
    tpl = x[start : start + tpl_len]
    lo = int(min_loop * SR)
    hi = min(int(max_loop * SR), x.size - start - tpl_len)
    if hi <= lo:
        raise SystemExit("音频太短，找不到循环")
    seg = x[start + lo : start + hi + tpl_len]
    score = ncc(seg, tpl, 0)
    # score[i] 对应 seg[i]，即绝对位置 start + lo + i
    best = int(np.argmax(score))
    sim = float(score[best])
    return start + lo + best, sim


def find_gap_before(x: np.ndarray, end: int, start: int, span: float = 0.25) -> int:
    """循环终点前如果有一小段静音（循环间隙），把裁剪点提前到静音开始处。"""
    win = 240  # 5 ms
    a = max(start + int(0.5 * SR), end - int(span * SR))
    b = end
    if b - a < win * 2:
        return end
    frames = x[a:b]
    n = frames.size // win
    rms = np.sqrt((frames[: n * win].reshape(n, win) ** 2).mean(axis=1))
    peak = np.abs(x[start:end]).max()
    thr = peak * 10 ** (-40.0 / 20.0)
    quiet = rms < thr
    # 从后往前数连续静音帧
    i = n - 1
    while i >= 0 and quiet[i]:
        i -= 1
    if i >= n - 1:
        return end
    quiet_len = (n - 1 - i) * win
    # 只有「确实存在间隙」并且间隙不夸张时才动裁剪点
    if 0 < quiet_len <= int(0.2 * SR):
        return a + (i + 1) * win
    return end


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])

    x = read_wav(src)
    start = find_start(x)
    end, sim = find_loop_end(x, start)
    cut = find_gap_before(x, end, start)
    if cut < end:
        end = cut

    tail = 0.04
    n_end = int(end)
    out = x[start:n_end].copy()
    # 末尾等功率交叉淡化：尾巴混进开头，消除循环接缝
    fade = int(tail * SR)
    if out.size > fade * 3:
        ramp = np.linspace(0.0, 1.0, fade)
        head = out[:fade].copy()
        out[-fade:] = out[-fade:] * np.cos(ramp * np.pi / 2) + head * np.sin(ramp * np.pi / 2)

    # 轻微归一化（只降不升），避免削波
    peak = float(np.abs(out).max())
    if peak > 0.98:
        out *= 0.98 / peak

    pcm = (np.clip(out, -1.0, 1.0) * 32767.0).astype("<i2")
    dst.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

    # --- 卡点分析：能量跃升最猛的位置 ---
    times, rms = rms_envelope(out)
    db = 20 * np.log10(np.maximum(rms, 1e-9))
    d = np.diff(db)
    onsets = np.argsort(d)[::-1][:8]
    onset_list = sorted([(round(float(times[i]), 2), round(float(d[i]), 1)) for i in onsets])

    # 每 0.5 s 的响度轮廓（给手动卡点参考）
    step = int(0.5 * SR)
    profile = []
    for i in range(0, out.size - step, step):
        seg = out[i : i + step]
        profile.append(round(float(20 * np.log10(max(np.sqrt((seg ** 2).mean()), 1e-9))), 1))

    info = {
        "source": str(src),
        "output": str(dst),
        "sample_rate": SR,
        "start_trim": round(start / SR, 3),
        "loop_end": round(end / SR, 3),
        "loop_length": round((end - start) / SR, 3),
        "similarity": round(sim, 3),
        "peak_dbfs": round(20 * np.log10(max(np.abs(out).max(), 1e-9)), 2),
        "onset_candidates": onset_list,
        "loudness_profile_0p5s": profile[:60],
    }
    print(json.dumps(info, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
