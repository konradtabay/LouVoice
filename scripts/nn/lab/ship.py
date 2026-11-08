"""Train the chosen recipe on every usable take and write Resources/Models/word_cnn.json (CNNWordModel format).

    python ship.py [--out ../../../Resources/Models/word_cnn.json] [--members 5] [--recent-weight 8]

Recipe (scripts/nn/lab/RESULTS.md):
- every isolated take of hello/can/you/hear/me/_none, quiz and calibration takes included; never `confirmed-*`
  (their labels came from the model's own guess);
- input: accelerometer + rotation + attitude (`"channels"` in the file; the app extracts the same, D62);
- takes from the latest session (recorded within --recent-hours of the newest take) weighted --recent-weight x;
- the shipped CNN architecture and augmentation (fast.py defaults), several members averaged.
"""
import argparse, json, os, sys
import numpy as np, torch
HERE = os.path.dirname(os.path.abspath(__file__))
p = argparse.ArgumentParser()
p.add_argument("--out", default=os.path.join(HERE, "../../../Resources/Models/word_cnn.json"))
p.add_argument("--members", type=int, default=5)
p.add_argument("--recent-weight", type=float, default=8.0)
p.add_argument("--recent-hours", type=float, default=3.0)
p.add_argument("--exclude-locked", action="store_true", help="leave the LOCKED test takes out (for checking only)")
a = p.parse_args()
torch.set_num_threads(4)
import harness as H, feats, fast

takes = H.load(raw=True)
feats.build(takes, "arv", channels=("a", "r", "v"))
pool = [t for t in takes if not t["block"].startswith("confirmed") and (not a.exclude_locked or t["id"] not in H.LOCKED_IDS)]
newest = max(t["created"] for t in pool)
recent = lambda t: t["created"] >= newest - a.recent_hours * 3600
print(f"{len(pool)} takes, {sum(map(recent, pool))} from the latest session (weighted {a.recent_weight}x)")
fit = fast.Fast(xkey="arv", VD=9, members=a.members,
                weight_fn=lambda ts: np.array([a.recent_weight if recent(t) else 1.0 for t in ts]))
predict = fit(pool, 0)
members = [{"scale": fit.scale.tolist(), "state": {k: v.detach().cpu().numpy().tolist() for k, v in net.state_dict().items()
                                                   if not k.endswith("num_batches_tracked")}} for net in fit.nets]
out = {"model": "cnn", "variant": "dedicated", "labels": H.LABELS, "T": fit.c["T"],
       "channels": ["acceleration", "rotation", "attitude"], "members": members,
       "recipe": "scripts/nn/lab/ship.py (D62)"}
json.dump(out, open(a.out, "w"))
print("wrote", os.path.abspath(a.out))

# Reference probabilities for the Swift check (LouVoiceCheck --cnn-ref): every pooled take, eval mode.
ref = {"ids": [t["id"] for t in pool], "probs": predict(pool).tolist(), "labels": H.LABELS}
json.dump(ref, open(os.path.join(H.DATA, "ship_ref.json"), "w"))
print("reference probabilities:", os.path.join(H.DATA, "ship_ref.json"))
