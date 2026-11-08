"""Short-time spectral magnitudes: for each channel, |rFFT| of a Hann window (W frames, hop H) -> W//2+1 bands.
Output is a (frames, channels*bands) time series, log1p-compressed."""
import numpy as np


def build(takes, key="x", out=None, W=8, H=2, padw=True):
    out = out or f"{key}_spec{W}"
    win = np.hanning(W)
    for t in takes:
        x = t.get(key)
        if x is None: t[out] = None; continue
        if padw: x = np.pad(x, ((W // 2, W // 2), (0, 0)))
        fr = [np.abs(np.fft.rfft(x[i:i + W] * win[:, None], axis=0)).T.reshape(-1) for i in range(0, max(1, len(x) - W + 1), H)]
        t[out] = np.log1p(np.array(fr, np.float32) * 10)
    return out
