"""Causal session axis alignment. For each take, the rotation-rate covariance of the N takes recorded before it
(labels unused, locked takes never feed it) is eigen-decomposed and rotated onto a reference frame (the
covariance of all daytime training takes) with the sign/order closest to identity. The same rotation is
applied to every xyz group. Deployable: the app keeps the last N takes' covariance."""
import itertools, numpy as np
import harness as H


def _rot_to(Es, Er):
    best, bestR = -1e9, np.eye(3)
    for perm in itertools.permutations(range(3)):
        for signs in itertools.product([1, -1], repeat=3):
            Ep = Es[:, perm] * np.array(signs)
            R = Er @ Ep.T
            if np.linalg.det(R) < 0: continue
            score = np.trace(R)  # closest to identity
            if score > best: best, bestR = score, R
    return bestR


def build(takes, key="x", groups=(0, 3), rgroup=0, out=None, N=40, minprev=10, maxdeg=60):
    out = out or key + "_al"
    order = sorted(takes, key=lambda t: t["created"])
    ref = np.cov(np.concatenate([t[key][:, rgroup:rgroup + 3] for t in order if not t["night"]
                                 and t.get(key) is not None and not t["block"].startswith("confirmed")]).T)
    _, Er = np.linalg.eigh(ref)
    hist = []
    for t in order:
        x = t.get(key)
        if x is None: t[out] = None; continue
        R = np.eye(3)
        if len(hist) >= minprev:
            C = np.cov(np.concatenate(hist[-N:]).T); _, Es = np.linalg.eigh(C)
            R = _rot_to(Es, Er)
            ang = np.degrees(np.arccos(np.clip((np.trace(R) - 1) / 2, -1, 1)))
            if ang > maxdeg: R = np.eye(3)
        y = x.copy()
        for g in groups: y[:, g:g + 3] = x[:, g:g + 3] @ R.T
        t[out] = y.astype(np.float32); t[out + "_deg"] = np.degrees(np.arccos(np.clip((np.trace(R) - 1) / 2, -1, 1)))
        if t["id"] not in H.LOCKED_IDS: hist.append(x[:, rgroup:rgroup + 3])
    return out
