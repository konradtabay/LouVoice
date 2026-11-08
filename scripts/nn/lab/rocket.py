"""ROCKET (random convolution kernels -> PPV/max features -> ridge) as a harness fit()."""
import numpy as np
from sklearn.linear_model import RidgeClassifierCV, LogisticRegression
from sklearn.preprocessing import StandardScaler


def make_kernels(D, K, T, rng):
    ks = []
    for _ in range(K):
        L = rng.choice([7, 9, 11]); w = rng.normal(size=(L, D)); w -= w.mean()
        chans = rng.random(D) < max(0.3, 1.0 / D); w[:, ~chans] = 0
        maxd = max(0, np.log2((T - 1) / (L - 1))); d = int(2 ** rng.uniform(0, maxd))
        ks.append((w.astype(np.float32), rng.uniform(-1, 1), d, bool(rng.random() < 0.5)))
    return ks


def transform(x, ks):
    n, D = x.shape; out = np.empty(2 * len(ks), np.float32)
    for i, (w, b, d, padq) in enumerate(ks):
        L = len(w); span = (L - 1) * d
        xp = np.pad(x, ((span // 2, span - span // 2), (0, 0))) if padq else x
        m = len(xp) - span
        if m <= 0: out[2 * i] = 0; out[2 * i + 1] = 0; continue
        idx = np.arange(m)[:, None] + np.arange(L)[None] * d
        c = np.einsum("mld,ld->m", xp[idx], w) + b
        out[2 * i] = (c > 0).mean(); out[2 * i + 1] = c.max()
    return out


class Rocket:
    def __init__(self, K=2000, xkey="x", seed=0, clf="ridge", norm=True):
        self.K, self.xkey, self.seed, self.clf, self.norm = K, xkey, seed, clf, norm

    def __call__(self, takes, seed=0):
        xk = self.xkey; takes = [t for t in takes if t.get(xk) is not None]
        rng = np.random.default_rng(self.seed + seed)
        scale = np.concatenate([t[xk] for t in takes]).std(0) + 1e-6
        T = int(np.median([len(t[xk]) for t in takes]))
        ks = make_kernels(takes[0][xk].shape[1], self.K, T, rng)
        prep = lambda x: x / scale / ((np.sqrt(((x / scale) ** 2).mean()) + 1e-9) if self.norm else 1)
        F = np.stack([transform(prep(t[xk]), ks) for t in takes]); y = np.array([t["y"] for t in takes])
        ss = StandardScaler().fit(F)
        if self.clf == "ridge":
            m = RidgeClassifierCV(alphas=np.logspace(-1, 4, 12), class_weight="balanced").fit(ss.transform(F), y)
        else:
            m = LogisticRegression(C=0.05, max_iter=2000, class_weight="balanced").fit(ss.transform(F), y)

        def predict(test):
            G = ss.transform(np.stack([transform(prep(t[xk]), ks) for t in test]))
            if self.clf == "ridge":
                s = m.decision_function(G); full = np.full((len(test), 6), -1e9); full[:, m.classes_] = s
                e = np.exp((full - full.max(1, keepdims=True)) * 5); return e / e.sum(1, keepdims=True)
            p = m.predict_proba(G); full = np.zeros((len(test), 6)); full[:, m.classes_] = p; return full
        return predict
