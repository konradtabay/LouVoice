"""Train the single-word CNN (D51) on this Mac's recorded takes and write Resources/Models/word_cnn.json.

    python3 -m venv .venv-nn && .venv-nn/bin/pip install torch numpy
    swift run -c release LouVoiceCheck --eval ~/Library/Application\\ Support/LouVoice/dataset.json \\
        --export-features /tmp/features.json
    .venv-nn/bin/python scripts/nn/train_word_cnn.py /tmp/features.json

Then rebuild the app (scripts/build-app.sh copies Resources/Models into the bundle).
Classes: the 5 words of word mode plus `_none` (the variant chosen in D51). Quiz takes are never used.
The architecture must match Sources/LouVoiceCore/CNNWordModel.swift.
"""
import argparse, json, math
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F

p = argparse.ArgumentParser()
p.add_argument("features")
p.add_argument("--out", default="Resources/Models/word_cnn.json")
p.add_argument("--words", default="hello,can,you,hear,me")
p.add_argument("--variant", default="dedicated", choices=["dedicated", "others-none", "all"],
               help="dedicated: only the words + _none; others-none: other words count as _none; all: every label")
p.add_argument("--members", type=int, default=3)
p.add_argument("--epochs", type=int, default=100)
p.add_argument("--T", type=int, default=48)
args = p.parse_args()
torch.set_num_threads(8)
NONE = "_none"
WORDS = args.words.split(",")

raw = json.load(open(args.features))
takes = []
for t in raw["takes"]:
    x = np.asarray(t["values"], np.float32).reshape(-1, t["dims"])
    if len(x) >= 4 and not t["test"]:
        takes.append(dict(x=x, label=t["label"], vd=t["vectorDims"]))
if args.variant == "dedicated":
    takes = [t for t in takes if t["label"] in WORDS + [NONE]]
elif args.variant == "others-none":
    takes = [dict(t, label=t["label"] if t["label"] in WORDS + [NONE] else NONE) for t in takes]
labels = sorted({t["label"] for t in takes}) if args.variant == "all" else WORDS + [NONE]
L = {l: i for i, l in enumerate(labels)}
D = takes[0]["x"].shape[1]; VD = takes[0]["vd"] - takes[0]["vd"] % 3
T = args.T
print(f"{len(takes)} training takes, classes {labels}")


def rot(rng, deg=12):
    a = rng.normal(size=3); a /= np.linalg.norm(a); th = math.radians(rng.uniform(-deg, deg))
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return (np.eye(3) + math.sin(th) * K + (1 - math.cos(th)) * K @ K).astype(np.float32)


def augment(x, rng):
    """Same family as Augment.swift: rotate xyz triplets (re-seating), time-warp, gain, jitter."""
    x = x.copy(); R = rot(rng)
    for g in range(0, VD, 3): x[:, g:g + 3] = x[:, g:g + 3] @ R.T
    x *= rng.uniform(0.85, 1.15)
    n = len(x); m = max(4, int(round(n * rng.uniform(0.8, 1.2)))); src = np.linspace(0, n - 1, m)
    x = np.stack([np.interp(src, np.arange(n), x[:, d]) for d in range(D)], 1).astype(np.float32)
    return x + rng.normal(scale=0.03, size=x.shape).astype(np.float32) * x.std(0, keepdims=True)


def to_fixed(x, rng=None):
    n = len(x); out = np.zeros((T, D), np.float32); mask = np.zeros(T, np.float32)
    if n >= T:
        s = (n - T) // 2 if rng is None else rng.integers(0, n - T + 1); out[:] = x[s:s + T]; mask[:] = 1
    else:
        s = (T - n) // 2 if rng is None else rng.integers(0, T - n + 1); out[s:s + n] = x; mask[s:s + n] = 1
    return out, mask


class CNN(nn.Module):
    def __init__(self, d, k, w=64, drop=0.3):
        super().__init__()
        self.convs = nn.ModuleList([nn.Conv1d(d, w, 5, padding=2), nn.Conv1d(w, w, 5, padding=2),
                                    nn.Conv1d(w, w, 5, padding=4, dilation=2), nn.Conv1d(w, w, 3, padding=4, dilation=4)])
        self.norms = nn.ModuleList([nn.BatchNorm1d(w) for _ in self.convs])
        self.drop = nn.Dropout(drop); self.head = nn.Linear(2 * w + 1, k)

    def forward(self, x, mask):
        h = x.transpose(1, 2)
        for i, (c, n) in enumerate(zip(self.convs, self.norms)):
            y = F.gelu(n(c(h))); h = y if i == 0 else h + y
        m = mask.unsqueeze(1)
        avg = (h * m).sum(2) / m.sum(2).clamp(min=1); mx = (h + (m - 1) * 1e4).amax(2)
        return self.head(self.drop(torch.cat([avg, mx, mask.sum(1, keepdim=True) / 50.0], 1)))


def fit(seed):
    rng = np.random.default_rng(seed); torch.manual_seed(seed)
    scale = np.concatenate([t["x"] for t in takes]).std(0) + 1e-6
    model = CNN(D, len(labels))
    opt = torch.optim.AdamW(model.parameters(), lr=3e-3, weight_decay=1e-2)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-3, total_steps=args.epochs * math.ceil(len(takes) / 64))
    y = np.array([L[t["label"]] for t in takes])
    w = np.bincount(y, minlength=len(labels)).astype(np.float32); w = (w.sum() / np.maximum(w, 1)) / len(labels)
    lossf = nn.CrossEntropyLoss(weight=torch.tensor(w), label_smoothing=0.1)
    model.train()
    for ep in range(args.epochs):
        idx = rng.permutation(len(takes))
        for b in range(0, len(idx), 64):
            xs, ms = zip(*[to_fixed(augment(takes[i]["x"] / scale, rng), rng) for i in idx[b:b + 64]])
            loss = lossf(model(torch.tensor(np.stack(xs)), torch.tensor(np.stack(ms))), torch.tensor(y[idx[b:b + 64]]))
            opt.zero_grad(); loss.backward(); opt.step(); sched.step()
    model.eval()
    print(f"  member {seed + 1}/{args.members} trained")
    return {"scale": scale.tolist(), "state": {k: v.tolist() for k, v in model.state_dict().items()}}


members = [fit(s) for s in range(args.members)]
json.dump({"model": "cnn", "variant": args.variant, "labels": labels, "T": T, "members": members}, open(args.out, "w"))
print("wrote", args.out)
