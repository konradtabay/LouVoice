"""Ceiling check on DEV blocks only: train on the pool + half of the block's takes (alternating per word),
test on the other half; both halves. Tells how separable words are when same-session data exists."""
import sys, numpy as np, torch
torch.set_num_threads(2)
import harness as H, fast, feats
raw = "--raw" in sys.argv
takes = H.load(raw)
if raw: feats.build(takes, 'arv', channels=('a', 'r', 'v'))
fit = eval(sys.argv[1])
ok = n = 0
for b in H.SPLIT["dev_blocks"]:
    bt = sorted([t for t in takes if t["block"] == b and t["label"] in H.WORDS], key=lambda t: t["created"])
    cnt = {}; half = []
    for t in bt: cnt[t["label"]] = cnt.get(t["label"], 0) + 1; half.append(cnt[t["label"]] % 2)
    for h in (0, 1):
        tr = [t for t, k in zip(bt, half) if k != h]; te = [t for t, k in zip(bt, half) if k == h]
        p = fit(H._pool(takes, {b}, True) + tr, 0)(te)
        ok += sum(np.argmax(pi) == t["y"] for pi, t in zip(p, te)); n += len(te)
print(f"IN-SESSION {sys.argv[1][:60]}: {ok}/{n} = {ok/n*100:.1f}%")
