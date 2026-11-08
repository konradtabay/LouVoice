"""DTW template classifier: per class, mean of the k smallest DTW distances to that class's training takes
(late-night ones by default), softmax(-d / temp). Uses the fold's own training takes only."""
import numpy as np


def dtw(a, b, band=None):
    n, m = len(a), len(b); c = np.sqrt(((a[:, None] - b[None]) ** 2).sum(-1))
    D = np.full((n + 1, m + 1), np.inf); D[0, 0] = 0
    for i in range(1, n + 1):
        lo, hi = (1, m) if band is None else (max(1, int(i * m / n) - band), min(m, int(i * m / n) + band))
        for j in range(lo, hi + 1):
            D[i, j] = c[i - 1, j - 1] + min(D[i - 1, j], D[i, j - 1], D[i - 1, j - 1])
    return D[n, m] / (n + m)


class DTWkNN:
    def __init__(self, xkey="x", sel=lambda t: t["night"], k=3, temp=0.05, band=8):
        self.xkey, self.sel, self.k, self.temp, self.band = xkey, sel, k, temp, band

    def __call__(self, takes, seed=0):
        tr = [t for t in takes if self.sel(t) and t.get(self.xkey) is not None]
        scale = np.concatenate([t[self.xkey] for t in takes if t.get(self.xkey) is not None]).std(0) + 1e-6
        by = {}
        for t in tr: by.setdefault(t["y"], []).append(t[self.xkey] / scale)

        def predict(test):
            P = np.zeros((len(test), 6))
            for i, t in enumerate(test):
                x = t[self.xkey] / scale; d = np.full(6, 1e3)
                for y, xs in by.items():
                    ds = sorted(dtw(x, z, self.band) for z in xs); d[y] = np.mean(ds[: self.k])
                e = np.exp(-(d - d.min()) / self.temp); P[i] = e / e.sum()
            return P
        return predict
