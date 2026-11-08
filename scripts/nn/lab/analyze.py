"""Dev confusion matrix for one config:  python analyze.py 'expr' [setup] [--raw]"""
import sys, numpy as np, torch
torch.set_num_threads(2)
import harness as H, fast, feats, nets, running
raw = "--raw" in sys.argv; args = [a for a in sys.argv[1:] if a != "--raw"]
takes = H.load(raw)
if len(args) > 1: exec(args[1])
fit = eval(args[0])
C = np.zeros((6, 6), int)
for b in H.SPLIT["dev_blocks"]:
    test = [t for t in takes if t["block"] == b and t["label"] in H.WORDS]
    p = fit(H._pool(takes, {b}, True), 0)(test)
    for t, pi in zip(test, p): C[t["y"], np.argmax(pi)] += 1
print("rows = true, cols = predicted:", H.LABELS)
for i in range(5): print(f"{H.LABELS[i]:6s}", " ".join(f"{v:3d}" for v in C[i]))
print("acc", np.trace(C) / C.sum())
