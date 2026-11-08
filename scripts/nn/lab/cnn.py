"""The shipped word CNN (train_word_cnn.py, D53) as a configurable fit() for the harness."""
import math
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F

torch.set_num_threads(10)


def rot(rng, deg):
    a = rng.normal(size=3); a /= np.linalg.norm(a); th = math.radians(rng.uniform(-deg, deg))
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return (np.eye(3) + math.sin(th) * K + (1 - math.cos(th)) * K @ K).astype(np.float32)


class CNN(nn.Module):
    def __init__(self, d, k, w=64, drop=0.3, layers=4):
        super().__init__()
        spec = [(5, 1), (5, 1), (5, 2), (3, 4), (3, 8), (3, 1)][:layers]
        self.convs = nn.ModuleList([nn.Conv1d(d if i == 0 else w, w, ks, padding=dl * (ks - 1) // 2, dilation=dl)
                                    for i, (ks, dl) in enumerate(spec)])
        self.norms = nn.ModuleList([nn.BatchNorm1d(w) for _ in self.convs])
        self.drop = nn.Dropout(drop); self.head = nn.Linear(2 * w + 1, k)

    def embed(self, x, mask):
        h = x.transpose(1, 2)
        for i, (c, n) in enumerate(zip(self.convs, self.norms)):
            y = F.gelu(n(c(h))); h = y if i == 0 else h + y
        m = mask.unsqueeze(1)
        avg = (h * m).sum(2) / m.sum(2).clamp(min=1); mx = (h + (m - 1) * 1e4).amax(2)
        return torch.cat([avg, mx, mask.sum(1, keepdim=True) / 50.0], 1)

    def forward(self, x, mask):
        return self.head(self.drop(self.embed(x, mask)))


DEFAULTS = dict(members=3, epochs=100, T=48, gain=(0.85, 1.15), rotdeg=12, warp=(0.8, 1.2), jitter=0.03,
                w=64, drop=0.3, layers=4, lr=3e-3, wd=1e-2, smooth=0.1, bs=64, VD=6, xkey="x",
                weight_fn=None, extra=None, tta=0)


class Fitter:
    def __init__(self, **kw):
        self.c = dict(DEFAULTS); self.c.update(kw)

    def augment(self, x, rng):
        c = self.c; x = x.copy(); D = x.shape[1]
        if c["rotdeg"]:
            R = rot(rng, c["rotdeg"])
            for g in range(0, c["VD"], 3): x[:, g:g + 3] = x[:, g:g + 3] @ R.T
        lo, hi = c["gain"]; x *= math.exp(rng.uniform(math.log(lo), math.log(hi)))
        n = len(x); m = max(4, int(round(n * rng.uniform(*c["warp"])))); src = np.linspace(0, n - 1, m)
        x = np.stack([np.interp(src, np.arange(n), x[:, d]) for d in range(D)], 1).astype(np.float32)
        if c["extra"]: x = c["extra"](x, rng)
        return x + rng.normal(scale=c["jitter"], size=x.shape).astype(np.float32) * x.std(0, keepdims=True)

    def fixed(self, x, rng=None):
        T = self.c["T"]; n, D = x.shape; out = np.zeros((T, D), np.float32); mask = np.zeros(T, np.float32)
        if n >= T:
            s = (n - T) // 2 if rng is None else rng.integers(0, n - T + 1); out[:] = x[s:s + T]; mask[:] = 1
        else:
            s = (T - n) // 2 if rng is None else rng.integers(0, T - n + 1); out[s:s + n] = x; mask[s:s + n] = 1
        return out, mask

    def __call__(self, takes, seed=0):
        c = self.c; k = 6; xk = c["xkey"]
        xs = [t[xk] for t in takes]; y = np.array([t["y"] for t in takes]); D = xs[0].shape[1]
        scale = np.concatenate(xs).std(0) + 1e-6
        nets = []
        for mi in range(c["members"]):
            s = seed * 100 + mi; rng = np.random.default_rng(s); torch.manual_seed(s)
            net = CNN(D, k, c["w"], c["drop"], c["layers"])
            opt = torch.optim.AdamW(net.parameters(), lr=c["lr"], weight_decay=c["wd"])
            steps = c["epochs"] * math.ceil(len(xs) / c["bs"])
            sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=c["lr"], total_steps=steps)
            cw = np.bincount(y, minlength=k).astype(np.float32); cw = (cw.sum() / np.maximum(cw, 1)) / k
            sw = c["weight_fn"](takes) if c["weight_fn"] else np.ones(len(xs), np.float32)
            lossf = nn.CrossEntropyLoss(weight=torch.tensor(cw), label_smoothing=c["smooth"], reduction="none")
            net.train()
            for ep in range(c["epochs"]):
                idx = rng.permutation(len(xs))
                for b in range(0, len(idx), c["bs"]):
                    bi = idx[b:b + c["bs"]]
                    if len(bi) < 2: continue
                    X, M = zip(*[self.fixed(self.augment(xs[i] / scale, rng), rng) for i in bi])
                    l = lossf(net(torch.tensor(np.stack(X)), torch.tensor(np.stack(M))), torch.tensor(y[bi]))
                    loss = (l * torch.tensor(sw[bi])).sum() / torch.tensor(sw[bi]).sum()
                    opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            net.eval(); nets.append(net)

        def predict(test):
            X, M = zip(*[self.fixed(t[xk] / scale) for t in test])
            X, M = torch.tensor(np.stack(X)), torch.tensor(np.stack(M))
            with torch.no_grad():
                return np.mean([F.softmax(n(X, M), 1).numpy() for n in nets], 0)
        return predict
