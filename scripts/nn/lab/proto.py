"""Prototypical network trained across sessions (episodes: prototypes from one block, queries from another),
jointly with the ordinary classification head. Inference blends the head's probabilities with distances to
prototypes built from the most recent labelled training takes (e.g. the calibration takes).
fit = Proto(...); fit(train_takes, seed) -> predict(test)."""
import math, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from cnn import CNN
from fast import Fast, pad, DEV


class Proto(Fast):
    def __init__(self, episodes=1500, k_shot=3, proj=64, w_proto=1.0, blend=0.5, recent_k=6, temp=1.0, **kw):
        super().__init__(**kw)
        self.p = dict(episodes=episodes, k_shot=k_shot, proj=proj, w_proto=w_proto, blend=blend, recent_k=recent_k, temp=temp)

    def __call__(self, takes, seed=0):
        c, P = self.c, self.p; xk = c["xkey"]
        takes = [t for t in takes if t.get(xk) is not None]
        xs = [t[xk] for t in takes]; y = torch.tensor([t["y"] for t in takes])
        scale = np.concatenate(xs).std(0) + 1e-6
        X, n = pad([x / scale for x in xs])
        sw = torch.tensor(c["weight_fn"](takes) if c["weight_fn"] else np.ones(len(xs)), dtype=torch.float32)
        cw = torch.bincount(y, minlength=6).float(); cw = ((cw.sum() / cw.clamp(min=1)) / 6).to(DEV)
        blocks = {}
        for i, t in enumerate(takes): blocks.setdefault(t["block"], {}).setdefault(int(t["y"]), []).append(i)
        good = [b for b, d in blocks.items() if sum(1 for k in range(5) if len(d.get(k, [])) >= 1) >= 4]
        nets = []
        for mi in range(c["members"]):
            s = seed * 100 + mi; g = torch.Generator().manual_seed(s); torch.manual_seed(s); rng = np.random.default_rng(s)
            net = CNN(X.shape[2], 6, c["w"], c["drop"], c["layers"]).to(DEV)
            proj = nn.Linear(2 * c["w"] + 1, P["proj"]).to(DEV)
            params = list(net.parameters()) + list(proj.parameters())
            opt = torch.optim.AdamW(params, lr=c["lr"], weight_decay=c["wd"])
            steps = P["episodes"]
            sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=c["lr"], total_steps=steps)
            net.train()
            for st in range(steps):
                # classification batch (as Fast)
                bi = torch.multinomial(sw, c["bs"], replacement=True, generator=g)
                A, M = self.augment(X[bi], n[bi], g)
                lc = F.cross_entropy(net(A.to(DEV), M.to(DEV)), y[bi].to(DEV), weight=cw, label_smoothing=c["smooth"])
                # episode: support block a, query block b (different), shared words
                a, b = rng.choice(len(good), 2, replace=False); da, db = blocks[good[a]], blocks[good[b]]
                ws = [k for k in range(6) if da.get(k) and db.get(k)]
                lp = torch.zeros((), device=DEV)
                if len(ws) >= 2:
                    sup = [int(rng.choice(da[k])) for k in ws for _ in range(P["k_shot"])]
                    qry = [int(rng.choice(db[k])) for k in ws for _ in range(2)]
                    As, Ms = self.augment(X[sup], n[sup], g); Aq, Mq = self.augment(X[qry], n[qry], g)
                    es = proj(net.embed(As.to(DEV), Ms.to(DEV))); eq = proj(net.embed(Aq.to(DEV), Mq.to(DEV)))
                    protos = es.view(len(ws), P["k_shot"], -1).mean(1)
                    logits = -torch.cdist(eq, protos) ** 2 / P["temp"]
                    tgt = torch.arange(len(ws), device=DEV).repeat_interleave(2)
                    lp = F.cross_entropy(logits, tgt)
                loss = lc + P["w_proto"] * lp
                opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            net.eval(); proj.eval(); nets.append((net, proj))

        # prototypes from the most recent labelled takes per class (deployable: the latest calibration/practice)
        order = sorted(range(len(takes)), key=lambda i: -takes[i]["created"])
        rec = {k: [i for i in order if int(takes[i]["y"]) == k][: P["recent_k"]] for k in range(6)}

        def predict(test):
            Xt, nt = pad([t[xk] / scale for t in test]); At, Mt = self.augment(Xt, nt, None, train=False)
            out = []
            with torch.no_grad():
                for net, proj in nets:
                    ph = F.softmax(net(At.to(DEV), Mt.to(DEV)), 1)
                    et = proj(net.embed(At.to(DEV), Mt.to(DEV)))
                    pr = []
                    for k in range(6):
                        idx = rec[k]
                        if not idx: pr.append(torch.zeros(et.shape[1], device=DEV) + 1e6); continue
                        Ar, Mr = self.augment(X[idx], n[idx], None, train=False)
                        pr.append(proj(net.embed(Ar.to(DEV), Mr.to(DEV))).mean(0))
                    pp = F.softmax(-torch.cdist(et, torch.stack(pr)) ** 2 / P["temp"], 1)
                    out.append((P["blend"] * pp + (1 - P["blend"]) * ph).cpu().numpy())
            return np.mean(out, 0)
        return predict
