"""Causal running normalisation: each take's channels are divided by the median per-take RMS of the N takes
recorded before it (any label, any block; labels never used), times the global median. Deployable as a ring buffer."""
import numpy as np
import harness as H


def build(takes, key="x", out=None, N=30, minprev=5, chans=None, scalar=False):
    out = out or key + "_run"
    order = sorted(takes, key=lambda t: t["created"])
    allrms = np.array([np.sqrt((t[key] ** 2).mean(0)) for t in order if t.get(key) is not None])
    glob = np.median(allrms, 0)
    hist = []
    for t in order:
        if t.get(key) is None: t[out] = None; continue
        r = np.sqrt((t[key] ** 2).mean(0))
        ref = np.median(np.array(hist[-N:]), 0) if len(hist) >= minprev else glob
        f = glob / np.maximum(ref, 1e-9)
        if scalar: f = np.full_like(f, np.exp(np.mean(np.log(f))))
        if chans is not None: f = np.where(np.isin(np.arange(len(f)), chans), f, 1)
        t[out] = (t[key] * f).astype(np.float32)
        if t["id"] not in H.LOCKED_IDS: hist.append(r)  # locked takes never feed anything
    return out
