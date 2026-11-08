"""Out-of-fold label check over the training pool only (never dev or locked blocks, never confirmed).
Group 5-fold by block; writes oof.json {id: p(true label)} for later filtering."""
import json, os, numpy as np, torch
torch.set_num_threads(2)
import harness as H, fast
ts = [t for t in H.load() if t["block"] not in H.LOCKED_BLOCKS and t["block"] not in H.SPLIT["dev_blocks"]
      and not t["block"].startswith("confirmed")]
blocks = sorted({t["block"] for t in ts}); rng = np.random.default_rng(0); rng.shuffle(blocks)
fold = {b: i % 5 for i, b in enumerate(blocks)}
oof = {}
for seed in (0, 1):
    for k in range(5):
        tr = [t for t in ts if fold[t["block"]] != k]; te = [t for t in ts if fold[t["block"]] == k]
        p = fast.Fast()(tr, seed)(te)
        for t, pi in zip(te, p): oof.setdefault(t["id"], []).append(float(pi[t["y"]]))
    print("seed", seed, "done", flush=True)
oof = {k: float(np.mean(v)) for k, v in oof.items()}
json.dump(oof, open(os.path.join(H.HERE, "oof.json"), "w"))
v = np.array(list(oof.values()))
for th in (0.02, 0.05, 0.1, 0.2): print(f"p(true) < {th}: {np.sum(v < th)} of {len(v)}")
