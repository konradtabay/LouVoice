"""Score the ship recipe on the frozen split:  python evaluate.py [--locked]
DEV and XS always; LOCKED only with --locked (every look is appended to locked_log.jsonl)."""
import sys, numpy as np, torch
torch.set_num_threads(4)
import harness as H, fast, feats
takes = H.load(raw=True); feats.build(takes, "arv", channels=("a", "r", "v"))
fit = fast.Fast(xkey="arv", VD=9, members=5, weight_fn=lambda ts: np.array([8.0 if t["night"] else 1.0 for t in ts]))
d = np.mean([H.dev(fit, f"evaluate.py seed{s}", raw=True, seed=s) for s in (0, 1)])
x = np.mean([H.xsess(fit, f"evaluate.py seed{s}", raw=True, seed=s) for s in (0, 1)])
print(f"DEV {d*100:.1f}%  XS {x*100:.1f}%  combined {(d*52 + x*55) / 107 * 100:.1f}%")
if "--locked" in sys.argv:
    l = np.mean([H.locked(fit, f"evaluate.py seed{s}", raw=True, seed=s) for s in (0, 1)])
    print(f"LOCKED {l*100:.1f}%")
