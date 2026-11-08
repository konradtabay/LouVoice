"""Time-normalised features: each take resampled to L frames, plus a constant channel log(original length)."""
import numpy as np


def build(takes, key="x", out=None, L=32, lenchan=True):
    out = out or f"{key}_n{L}"
    for t in takes:
        x = t.get(key)
        if x is None: t[out] = None; continue
        src = np.linspace(0, len(x) - 1, L)
        z = np.stack([np.interp(src, np.arange(len(x)), x[:, d]) for d in range(x.shape[1])], 1)
        if lenchan: z = np.concatenate([z, np.full((L, 1), np.log(len(x) / 20.0))], 1)
        t[out] = z.astype(np.float32)
    return out
