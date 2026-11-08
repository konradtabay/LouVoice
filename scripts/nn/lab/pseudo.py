"""Keep only the 'confirmed' takes whose label a clean model (trained in-fold without them) agrees with."""
import numpy as np


class Pseudo:
    def __init__(self, base, final=None, thr=0.5):
        self.base, self.final, self.thr = base, final or base, thr

    def __call__(self, takes, seed=0):
        conf = [t for t in takes if t["block"].startswith("confirmed")]
        clean = [t for t in takes if not t["block"].startswith("confirmed")]
        p = self.base(clean, seed)(conf) if conf else np.zeros((0, 6))
        keep = [t for t, pi in zip(conf, p) if np.argmax(pi) == t["y"] and pi[t["y"]] >= self.thr]
        self.kept = (len(keep), len(conf))
        print(f"  pseudo: kept {len(keep)}/{len(conf)} confirmed takes", flush=True)
        return self.final(clean + keep, seed)
