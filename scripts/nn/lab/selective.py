"""Selective accuracy on DEV + XS (never locked): collect held-out probabilities, then accuracy among answered takes
and coverage per confidence threshold.  python selective.py 'expr' 'setup' [--raw]"""
import sys, numpy as np, torch, json
torch.set_num_threads(2)
import harness as H, fast, feats, tnorm, ens
raw = "--raw" in sys.argv; args = [a for a in sys.argv[1:] if a != "--raw"]
takes = H.load(raw)
if len(args) > 1: exec(args[1])
fit = eval(args[0])
P, Y = [], []
for b in H.SPLIT["dev_blocks"]:
    test = [t for t in takes if t["block"] == b and t["label"] in H.WORDS]
    P += list(fit(H._pool(takes, {b}, True), 0)(test)); Y += [t["y"] for t in test]
nd = len(Y)
for s in H.XS_SESSIONS:
    test = [t for t in takes if s in t["block"] and t["quiz"] and t["label"] in H.WORDS]
    P += list(fit([t for t in H._pool(takes, set(), True) if s not in t["block"]], 0)(test)); Y += [t["y"] for t in test]
P, Y = np.array(P), np.array(Y)
json.dump({"P": P.tolist(), "Y": Y.tolist(), "ndev": nd}, open("logs/selective_" + str(abs(hash(args[0])) % 10**6) + ".json", "w"))
for name, sl in (("DEV", slice(0, nd)), ("XS", slice(nd, None)), ("ALL", slice(None))):
    p, y = P[sl], Y[sl]; conf = p.max(1); right = p.argmax(1) == y
    print(f"{name}: plain {right.mean()*100:.1f}%")
    for th in (0.5, 0.6, 0.7, 0.8, 0.9):
        k = conf >= th
        if k.sum(): print(f"   conf >= {th}: answers {k.mean()*100:5.1f}%  right when answering {right[k].mean()*100:5.1f}%")
