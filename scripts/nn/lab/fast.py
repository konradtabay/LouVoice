"""Vectorised trainer: augmentation (rotation, gain, time-warp + crop, jitter, ...) runs in torch on whole batches.
fit = Fast(**cfg); fit(train_takes, seed) -> predict(takes) -> (n, 6) probs."""
import math
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from cnn import CNN

DEV = torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def pad(xs, L=None):
    L = L or max(len(x) for x in xs); D = xs[0].shape[1]
    X = np.zeros((len(xs), L, D), np.float32); n = np.zeros(len(xs), np.int64)
    for i, x in enumerate(xs): x = x[:L]; X[i, :len(x)] = x; n[i] = len(x)
    return torch.tensor(X), torch.tensor(n)


def rand_rot(B, deg, g):
    a = torch.randn(B, 3, generator=g); a = a / a.norm(dim=1, keepdim=True)
    th = (torch.rand(B, generator=g) * 2 - 1) * math.radians(deg)
    K = torch.zeros(B, 3, 3); K[:, 0, 1], K[:, 0, 2], K[:, 1, 0] = -a[:, 2], a[:, 1], a[:, 2]
    K[:, 1, 2], K[:, 2, 0], K[:, 2, 1] = -a[:, 0], -a[:, 1], a[:, 0]
    s, c = th.sin()[:, None, None], th.cos()[:, None, None]
    return torch.eye(3) + s * K + (1 - c) * K @ K


def warp_crop(X, n, T, lo, hi, g, center=False):
    """Resample each take by factor u in [lo, hi] (log-uniform) and place it in a T-frame window
    (random crop if longer, random offset if shorter). Linear interpolation. Returns (B,T,D), mask (B,T)."""
    B, L, D = X.shape
    u = torch.exp(torch.empty(B).uniform_(math.log(lo), math.log(hi), generator=g)) if not center else torch.ones(B)
    m = torch.clamp((n.float() * u).round(), min=4)                       # warped length
    step = (n.float() - 1) / (m - 1).clamp(min=1)                          # source frames per output frame
    r = torch.rand(B, generator=g) if not center else torch.full((B,), 0.5)
    if center:  # same as CNNWordModel.input in Swift: start (n - T) / 2 when longer, offset (T - n) / 2 when shorter
        off = torch.where(m >= T, -((m - T) / 2).floor(), ((T - m) / 2).floor())
    else:
        off = torch.where(m >= T, -(r * (m - T + 1)).floor(), (r * (T - m + 1)).floor())
    j = torch.arange(T).float()[None]
    k = j - off[:, None]                                                   # index in warped sequence
    valid = (k >= 0) & (k <= m[:, None] - 1)
    pos = (k * step[:, None]).clamp(min=0); pos = torch.minimum(pos, (n[:, None] - 1).float())
    i0 = pos.floor().long(); i1 = torch.minimum(i0 + 1, (n[:, None] - 1)); f = (pos - i0.float())[..., None]
    gi = lambda idx: torch.gather(X, 1, idx[..., None].expand(B, T, D))
    out = (gi(i0) * (1 - f) + gi(i1) * f) * valid[..., None]
    return out, valid.float()


class Fast:
    DEFAULTS = dict(members=3, epochs=100, T=48, gain=(0.85, 1.15), rotdeg=12, warp=(0.8, 1.2), jitter=0.03,
                    w=64, drop=0.3, layers=4, lr=3e-3, wd=1e-2, smooth=0.1, bs=64, VD=6, xkey="x",
                    weight_fn=None, chan_gain=0.0, time_mask=0, mixup=0.0, yaw_only=False, yawdeg=0,
                    synth=None, synth_n=0, net=None, inorm=False, tta=0)

    def __init__(self, **kw):
        self.c = dict(self.DEFAULTS); self.c.update(kw)

    def augment(self, X, n, g, train=True):
        c = self.c; B, L, D = X.shape; X = X.clone()
        if not train:
            return warp_crop(X, n, c["T"], 1, 1, g, center=True)
        if c["rotdeg"] or c["yawdeg"]:
            R = rand_rot(B, c["rotdeg"], g) if c["rotdeg"] else torch.eye(3).repeat(B, 1, 1)
            if c["yawdeg"]:
                th = (torch.rand(B, generator=g) * 2 - 1) * math.radians(c["yawdeg"])
                Y = torch.zeros(B, 3, 3); Y[:, 0, 0] = th.cos(); Y[:, 0, 1] = -th.sin(); Y[:, 1, 0] = th.sin(); Y[:, 1, 1] = th.cos(); Y[:, 2, 2] = 1
                R = Y @ R
            for k in range(0, c["VD"], 3): X[:, :, k:k + 3] = X[:, :, k:k + 3] @ R.transpose(1, 2)
        lo, hi = c["gain"]
        X = X * torch.exp(torch.empty(B, 1, 1).uniform_(math.log(lo), math.log(hi), generator=g))
        if c["chan_gain"]:
            X = X * torch.exp(torch.randn(B, 1, D, generator=g) * c["chan_gain"])
        out, M = warp_crop(X, n, c["T"], *c["warp"], g)
        if c["jitter"]:
            sd = (out.pow(2).sum(1) / M.sum(1, keepdim=True).clamp(min=1)).sqrt()[:, None]
            out = out + torch.randn(out.shape, generator=g) * c["jitter"] * sd * M[..., None]
        if c["time_mask"]:
            w = c["time_mask"]; st = (torch.rand(B, generator=g) * c["T"]).long()
            j = torch.arange(c["T"])[None]; cut = (j >= st[:, None]) & (j < st[:, None] + w)
            out = out * (~cut)[..., None]
        return out, M

    def make_net(self, D):
        c = self.c
        return c["net"](D) if c["net"] else CNN(D, getattr(self, "K", 6), c["w"], c["drop"], c["layers"])

    def finetune(self, net, X, n, y, takes, cwd, g):
        """Second stage: keep training on the selected (e.g. same-evening) takes, mixed with replayed others."""
        f = self.c["ft"]; c = self.c
        sel = torch.tensor([i for i, t in enumerate(takes) if f["sel"](t)])
        if len(sel) < 4: return
        opt = torch.optim.AdamW(net.parameters(), lr=f.get("lr", 5e-4), weight_decay=c["wd"])
        net.train()
        for ep in range(f.get("epochs", 40)):
            perm = sel[torch.randperm(len(sel), generator=g)]
            for b in range(0, len(perm), 32):
                bi = perm[b:b + 32]
                rep = torch.randint(0, len(takes), (int(len(bi) * f.get("replay", 1.0)),), generator=g)
                bi = torch.cat([bi, rep])
                A, M = self.augment(X[bi], n[bi], g)
                l = F.cross_entropy(net(A.to(DEV), M.to(DEV)), y[bi].to(DEV), weight=cwd, label_smoothing=c["smooth"])
                opt.zero_grad(); l.backward(); opt.step()

    def adabn(self, net, past, T0, r):
        """Re-measure BatchNorm stats on the K most recent takes before T0 (labels unused), blend with trained."""
        idx = torch.nonzero(past).flatten()
        if len(idx) == 0: return
        rec = idx[torch.argsort(self._created[idx], descending=True)[: r.get("K", 40)]]
        bns = [m for m in net.modules() if isinstance(m, nn.BatchNorm1d)]
        old = [(b.running_mean.clone(), b.running_var.clone()) for b in bns]
        for b in bns: b.reset_running_stats(); b.momentum = None
        net.train()
        with torch.no_grad():
            A, M = self.augment(self._X[rec], self._n[rec], None, train=False)
            net(A.to(DEV), M.to(DEV))
        a = r.get("alpha", 0.5)
        for b, (m0, v0) in zip(bns, old):
            b.running_mean.mul_(a).add_((1 - a) * m0); b.running_var.mul_(a).add_((1 - a) * v0); b.momentum = 0.1

    def __call__(self, takes, seed=0):
        c = self.c; xk = c["xkey"]
        takes = [t for t in takes if t.get(xk) is not None and (c.get("filt") is None or c["filt"](t))]
        xs = [t[xk] for t in takes]; y = torch.tensor([t["y"] for t in takes])
        scale = np.concatenate(xs).std(0) + 1e-6
        X, n = pad([x / scale for x in xs])
        bank = None
        if c.get("xaug"):  # precomputed physical variants: (N, V+1, L, D), slot 0 = original
            Vn = max(len(t[xk + "_aug"]) for t in takes); L = max(X.shape[1], max(len(v) for t in takes for v in t[xk + "_aug"]))
            bank = torch.zeros(len(xs), Vn + 1, L, X.shape[2]); bn = torch.zeros(len(xs), Vn + 1, dtype=torch.long)
            for i, t in enumerate(takes):
                vs = [xs[i]] + list(t[xk + "_aug"]); vs += [vs[j % len(vs)] for j in range(Vn + 1 - len(vs))]
                for j, v in enumerate(vs): v = v[:L]; bank[i, j, :len(v)] = torch.tensor(v / scale); bn[i, j] = len(v)
            self._bank = (bank, bn)
        sw = torch.tensor(c["weight_fn"](takes) if c["weight_fn"] else np.ones(len(xs)), dtype=torch.float32)
        K = int(y.max()) + 1 if int(y.max()) >= 6 else 6; self.K = K
        cw = torch.bincount(y, minlength=K).float(); cw = (cw.sum() / cw.clamp(min=1)) / K
        nets = []
        for mi in range(c["members"]):
            s = seed * 100 + mi; g = torch.Generator().manual_seed(s); torch.manual_seed(s)
            net = self.make_net(X.shape[2]).to(DEV); cwd = cw.to(DEV)
            opt = torch.optim.AdamW(net.parameters(), lr=c["lr"], weight_decay=c["wd"])
            steps = c["epochs"] * math.ceil(len(xs) / c["bs"])
            sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=c["lr"], total_steps=steps)
            net.train()
            for ep in range(c["epochs"]):
                idx = torch.randperm(len(xs), generator=g)
                for b in range(0, len(idx), c["bs"]):
                    bi = idx[b:b + c["bs"]]
                    if len(bi) < 2: continue
                    if bank is not None:
                        vi = torch.randint(0, bank.shape[1], (len(bi),), generator=g)
                        vi = torch.where(torch.rand(len(bi), generator=g) < c.get("p_orig", 0.25), 0, vi)
                        A, M = self.augment(bank[bi, vi], bn[bi, vi], g)
                    else:
                        A, M = self.augment(X[bi], n[bi], g)
                    yb = y[bi]; wb = sw[bi]
                    if c["synth"] is not None and c["synth_n"]:
                        As, Ms, ys = c["synth"](c["synth_n"], g, self, scale)
                        A = torch.cat([A, As]); M = torch.cat([M, Ms]); yb = torch.cat([yb, ys]); wb = torch.cat([wb, torch.ones(len(ys))])
                    A, M, yb, wb = A.to(DEV), M.to(DEV), yb.to(DEV), wb.to(DEV)
                    if c["mixup"]:
                        lam = float(np.random.default_rng(s + ep * 1000 + b).beta(c["mixup"], c["mixup"]))
                        perm = torch.randperm(len(A), generator=g).to(DEV)
                        logits = net(lam * A + (1 - lam) * A[perm], torch.maximum(M, M[perm]))
                        l = lam * F.cross_entropy(logits, yb, weight=cwd, label_smoothing=c["smooth"], reduction="none") + \
                            (1 - lam) * F.cross_entropy(logits, yb[perm], weight=cwd, label_smoothing=c["smooth"], reduction="none")
                    else:
                        l = F.cross_entropy(net(A, M), yb, weight=cwd, label_smoothing=c["smooth"], reduction="none")
                    loss = (l * wb).sum() / wb.sum()
                    opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            if c.get("ft"):
                self.finetune(net, X, n, y, takes, cwd, g)
            net.eval(); nets.append(net)
        self.nets, self.scale = nets, scale

        created = torch.tensor([t["created"] for t in takes], dtype=torch.float64)
        self._created, self._X, self._n = created, X, n

        grest = torch.tensor(np.stack([t.get("grest", np.zeros(3)) for t in takes]), dtype=torch.float64)

        def adapt_w(w, r):
            import copy
            out = []
            for k, base in enumerate(nets):
                net = copy.deepcopy(base); g = torch.Generator().manual_seed(2000 + k)
                opt = torch.optim.AdamW(net.parameters(), lr=r.get("lr", 5e-4), weight_decay=c["wd"]); net.train()
                for st in range(r.get("steps", 150)):
                    bi = torch.cat([torch.multinomial(w, r.get("bs", 32), replacement=True, generator=g),
                                    torch.randint(0, len(takes), (int(r.get("bs", 32) * r.get("replay", 1.0)),), generator=g)])
                    A, M = self.augment(X[bi], n[bi], g)
                    l = F.cross_entropy(net(A.to(DEV), M.to(DEV)), y[bi].to(DEV), weight=cw.to(DEV), label_smoothing=c["smooth"])
                    opt.zero_grad(); l.backward(); opt.step()
                net.eval(); out.append(net)
            return out

        def adapt(T0):
            """Causal recency fine-tune: copies of the nets, trained on takes recorded before T0,
            sampled with weight exp(-(T0 - t) / tau) and mixed with uniform replay."""
            import copy
            r = c["rec"]; past = created < T0
            if past.sum() < 8: return nets
            w = torch.where(past, torch.exp(-(T0 - created) / (60 * r.get("tau_min", 30))), torch.zeros(1, dtype=torch.float64)).float()
            if w.sum() <= 0: return nets
            out = []
            for k, base in enumerate(nets):
                net = copy.deepcopy(base); g = torch.Generator().manual_seed(1000 + k)
                opt = torch.optim.AdamW(net.parameters(), lr=r.get("lr", 5e-4), weight_decay=c["wd"]); net.train()
                for st in range(r.get("steps", 150)):
                    bi = torch.cat([torch.multinomial(w, r.get("bs", 32), replacement=True, generator=g),
                                    torch.multinomial(past.float(), int(r.get("bs", 32) * r.get("replay", 1.0)), replacement=True, generator=g)])
                    A, M = self.augment(X[bi], n[bi], g)
                    l = F.cross_entropy(net(A.to(DEV), M.to(DEV)), y[bi].to(DEV), weight=cw.to(DEV), label_smoothing=c["smooth"])
                    opt.zero_grad(); l.backward(); opt.step()
                if r.get("adabn"):
                    self.adabn(net, past, T0, r)
                net.eval(); out.append(net)
            return out

        def predict(test):
            if c.get("fitmatch"):
                r = c["fitmatch"]; order = sorted(range(len(test)), key=lambda i: test[i]["created"]); groups, cur = [], [order[0]]
                for i in order[1:]:
                    if test[i]["created"] - test[cur[-1]]["created"] > 600: groups.append(cur); cur = [i]
                    else: cur.append(i)
                groups.append(cur); P = np.zeros((len(test), 6))
                for gi in groups:
                    g0 = torch.tensor(np.mean([test[i]["grest"] for i in gi], 0), dtype=torch.float64)
                    w = torch.exp(-((grest - g0) ** 2).sum(1) / (2 * r.get("sigma", 0.05) ** 2)).float()
                    P[gi] = run([test[i] for i in gi], adapt_w(w, r))
                return P
            if c.get("rec"):
                order = sorted(range(len(test)), key=lambda i: test[i]["created"]); groups, cur = [], [order[0]]
                for i in order[1:]:
                    if test[i]["created"] - test[cur[-1]]["created"] > 600: groups.append(cur); cur = [i]
                    else: cur.append(i)
                groups.append(cur); P = np.zeros((len(test), 6))
                for gi in groups:
                    T0 = min(test[i]["created"] for i in gi)
                    P[gi] = run([test[i] for i in gi], adapt(T0))
                return P
            return run(test, nets)

        def run(test, nets):
            Xt, nt = pad([t[xk] / scale if t.get(xk) is not None else np.zeros((4, X.shape[2]), np.float32) for t in test])
            g = torch.Generator().manual_seed(0)
            A, M = self.augment(Xt, nt, g, train=False)
            with torch.no_grad():
                p = np.mean([F.softmax(m(A.to(DEV), M.to(DEV)), 1).cpu().numpy() for m in nets], 0)
                if c["tta"]:
                    for _ in range(c["tta"]):
                        A2, M2 = self.augment(Xt, nt, g, train=True)
                        p = p + np.mean([F.softmax(m(A2.to(DEV), M2.to(DEV)), 1).cpu().numpy() for m in nets], 0)
                    p = p / (c["tta"] + 1)
            p = p[:, :6]
            return p / p.sum(1, keepdims=True)
        return predict
