"""Run one experiment on DEV:  python run.py NAME 'python-expr returning a fit callable' [--seeds 0,1] [--raw] [--none]
The expression sees: harness as H, cnn, fast, feats, np, torch. A 'setup' expression (--setup) runs first
(e.g. building raw feature keys). Logs the mean over seeds to dev_log.jsonl (as NAME@mean)."""
import sys, os, argparse, json, time
p = argparse.ArgumentParser(); p.add_argument("name"); p.add_argument("expr")
p.add_argument("--threads", type=int, default=2); p.add_argument("--raw", action="store_true")
p.add_argument("--none", action="store_true"); p.add_argument("--seeds", default="0,1")
p.add_argument("--keep-confirmed", action="store_true"); p.add_argument("--setup", default="")
a = p.parse_args()
import torch; torch.set_num_threads(a.threads)
import numpy as np, harness as H, cnn, fast, feats, nets, rocket
if a.setup:
    takes = H.load(a.raw); exec(a.setup)
fit = eval(a.expr)
accs = [H.dev(fit, f"{a.name}#s{s}", raw=a.raw, drop_confirmed=not a.keep_confirmed, seed=int(s)) for s in a.seeds.split(",")]
m = float(np.mean(accs))
print(f"MEAN {a.name}: {m*100:.1f}%  ({' '.join(f'{x*100:.1f}' for x in accs)})", flush=True)
with open(os.path.join(H.HERE, "results.tsv"), "a") as fh:
    fh.write(f"{time.strftime('%m-%d %H:%M')}\t{a.name}\t{m*100:.1f}\t{' '.join(f'{x*100:.1f}' for x in accs)}\t{a.expr}\t{a.setup}\n")
if a.none: H.none_check(fit, raw=a.raw, seed=0)
