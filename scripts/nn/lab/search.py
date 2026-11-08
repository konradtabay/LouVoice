"""Endless random search around the arv_nw8 recipe; each config scored on DEV + XS (2 seeds), appended to
search.tsv. Never touches LOCKED.  python search.py [worker_id]"""
import sys, json, os, time, random, numpy as np, torch
torch.set_num_threads(2)
import harness as H, fast, feats
wid = int(sys.argv[1]) if len(sys.argv) > 1 else 0
rng = random.Random(1000 + wid * 7919 + int(time.time()))
takes = H.load(True); feats.build(takes, 'arv', channels=('a', 'r', 'v'))
SPACE = dict(lr=[1e-3, 2e-3, 3e-3, 5e-3], wd=[1e-3, 1e-2, 3e-2, 1e-1], smooth=[0.0, 0.05, 0.1, 0.2], drop=[0.1, 0.3, 0.5],
             w=[48, 64, 96], T=[40, 48, 56], epochs=[60, 100, 150], rotdeg=[0, 6, 12, 20], gain_lo=[0.6, 0.75, 0.85],
             gain_hi=[1.15, 1.3, 1.5], warp_lo=[0.7, 0.8, 0.9], warp_hi=[1.1, 1.2, 1.3], jitter=[0.0, 0.03, 0.06],
             nw=[4.0, 6.0, 8.0, 12.0], bs=[32, 64], time_mask=[0, 0, 4])
while True:
    cfg = {k: rng.choice(v) for k, v in SPACE.items()}
    nw = cfg.pop("nw"); g = (cfg.pop("gain_lo"), cfg.pop("gain_hi")); wp = (cfg.pop("warp_lo"), cfg.pop("warp_hi"))
    fit = fast.Fast(xkey='arv', VD=9, gain=g, warp=wp, weight_fn=lambda ts, nw=nw: np.array([nw if t['night'] else 1.0 for t in ts]), **cfg)
    d = [H.dev(fit, "search", raw=True, seed=s, verbose=False) for s in (0, 1)]
    x = [H.xsess(fit, "search", raw=True, seed=s, verbose=False) for s in (0, 1)]
    comb = (np.mean(d) * 52 + np.mean(x) * 55) / 107
    row = dict(cfg, nw=nw, gain=g, warp=wp, dev=float(np.mean(d)), xs=float(np.mean(x)), comb=float(comb))
    with open(os.path.join(H.HERE, "search.tsv"), "a") as fh: fh.write(json.dumps(row) + "\n")
    print(f"[{wid}] comb {comb*100:.1f} dev {np.mean(d)*100:.1f} xs {np.mean(x)*100:.1f} {row}", flush=True)
