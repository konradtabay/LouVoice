"""In-domain synthetic takes: DTW-align two same-label takes from the fold's own training data (late-night by
default) and interpolate along the warping path, then resample to an interpolated length. Strict: only
uses the takes handed to fit()."""
import numpy as np


def dtw_path(a, b):
    n, m = len(a), len(b); c = np.sqrt(((a[:, None] - b[None]) ** 2).sum(-1))
    D = np.full((n + 1, m + 1), np.inf); D[0, 0] = 0
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            D[i, j] = c[i - 1, j - 1] + min(D[i - 1, j], D[i, j - 1], D[i - 1, j - 1])
    i, j, p = n, m, []
    while i > 0 and j > 0:
        p.append((i - 1, j - 1)); k = np.argmin([D[i - 1, j - 1], D[i - 1, j], D[i, j - 1]])
        i, j = (i - 1, j - 1) if k == 0 else (i - 1, j) if k == 1 else (i, j - 1)
    return p[::-1]


def blend(a, b, lam, sa, rng):
    p = dtw_path(a / sa, b / sa)
    seq = np.array([(1 - lam) * a[i] + lam * b[j] for i, j in p], np.float32)
    L = max(4, int(round((1 - lam) * len(a) + lam * len(b))))
    src = np.linspace(0, len(seq) - 1, L)
    return np.stack([np.interp(src, np.arange(len(seq)), seq[:, d]) for d in range(seq.shape[1])], 1).astype(np.float32)


class Synth:
    def __init__(self, base, n=200, sel=lambda t: t["night"], keys=("x",), lam=(0.2, 0.8)):
        self.base, self.n, self.sel, self.keys, self.lam = base, n, sel, keys, lam

    def __call__(self, takes, seed=0):
        rng = np.random.default_rng(seed + 7)
        src = [t for t in takes if self.sel(t)]
        by = {}
        for t in src: by.setdefault(t["y"], []).append(t)
        out = []
        ys = [y for y, v in by.items() if len(v) >= 2]
        for k in range(self.n):
            y = ys[k % len(ys)]; a, b = rng.choice(len(by[y]), 2, replace=False); lam = rng.uniform(*self.lam)
            ta, tb = by[y][a], by[y][b]; s = dict(ta); s["id"] = f"synth{k}"; s["block"] = "synth"
            for key in self.keys:
                if ta.get(key) is None or tb.get(key) is None: s[key] = ta.get(key); continue
                sa = np.concatenate([ta[key], tb[key]]).std(0) + 1e-6
                s[key] = blend(ta[key], tb[key], lam, sa, rng)
            out.append(s)
        return self.base(takes + out, seed)
