"""Python re-implementation of Features.extract (Features.swift) with extra options, built from raw samples.
raw columns: r(0:3) a(3:6) g(6:9) q(9:13, w x y z) p(13:16)."""
import numpy as np
from scipy.signal import butter, lfilter


def resample(raw, t, rate):
    o = np.argsort(t, kind="stable"); raw, t = raw[o], t[o]
    tt = t - t[0]; n = int(np.floor(tt[-1] * rate)) + 1
    grid = np.arange(n) / rate
    out = np.stack([np.interp(grid, tt, raw[:, d]) for d in range(raw.shape[1])], 1)
    q = out[:, 9:13]; out[:, 9:13] = q / np.linalg.norm(q, axis=1, keepdims=True)
    return out


def aligning(g, to=np.array([0, 0, -1.0])):
    a = g / np.linalg.norm(g); b = to; v = np.cross(a, b); c = float(a @ b)
    if np.linalg.norm(v) < 1e-9: return np.eye(3) if c > 0 else -np.eye(3)
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K * (1 / (1 + c))


def qmul(a, b):
    w1, x1, y1, z1 = a.T; w2, x2, y2, z2 = b.T
    return np.stack([w1*w2 - x1*x2 - y1*y2 - z1*z2, w1*x2 + x1*w2 + y1*z2 - z1*y2,
                     w1*y2 - x1*z2 + y1*w2 + z1*x2, w1*z2 + x1*y2 - y1*x2 + z1*w2], 1)


def rotvec(q):
    q = q * np.sign(q[:, :1] + 1e-12); w = np.clip(q[:, 0], -1, 1); v = q[:, 1:]
    s = np.linalg.norm(v, axis=1); ang = 2 * np.arctan2(s, w)
    return v * (ang / np.maximum(s, 1e-12))[:, None]


def highpass(x, cutoff, rate):
    n = len(x)
    if n < 4 or cutoff <= 0: return x
    pad = min(n - 1, int(rate))
    xp = np.concatenate([2 * x[0] - x[pad:0:-1], x, 2 * x[-1] - x[-2:-pad - 2:-1]])
    y = biquad_hp(biquad_hp(xp, cutoff, rate)[::-1], cutoff, rate)[::-1]
    return y[pad:pad + n]


def biquad_hp(x, cutoff, rate):
    """Signal.Biquad(highPass:).run: RBJ, Q = 1/sqrt(2), started in steady state (x1 = x2 = x0, y = 0)."""
    w0 = 2 * np.pi * cutoff / rate; al = np.sin(w0) / (2 * np.sqrt(0.5)); c = np.cos(w0); a0 = 1 + al
    b0, b1, b2, a1, a2 = (1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0
    y = np.zeros_like(x); x1 = x2 = x[0].copy(); y1 = np.zeros_like(x[0]); y2 = np.zeros_like(x[0])
    for i in range(len(x)):
        v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x[i], y1, v; y[i] = v
    return y


def extract(raw, t, rate=25, hp=0.8, rest=0.3, channels=("r", "v"), trim=True, mags=True, thr=0.35,
            smooth=0.2, padsec=0.08, deriv=False, canon=True, extra=(), norm=None, R=None, gain=1.0):
    s = resample(raw, t, rate)
    if R is not None:
        s = s.copy(); s[:, 0:3] = s[:, 0:3] @ R.T; s[:, 3:6] = s[:, 3:6] @ R.T; s[:, 6:9] = s[:, 6:9] @ R.T
    if len(s) < 6: return None
    rc = max(1, min(len(s), int(rest * rate)))
    C = aligning(s[:rc, 6:9].sum(0)) if canon else np.eye(3)
    a = s[:, 3:6] @ C.T; r = s[:, 0:3] @ C.T
    q0 = s[0, 9:13] * np.array([1, -1, -1, -1]); rel = rotvec(qmul(np.repeat(q0[None], len(s), 0), s[:, 9:13]))
    if R is not None: rel = rel @ R.T
    if gain != 1.0: r = r * gain; a = a * gain; rel = rel * gain
    v = rel @ C.T
    ch = {"a": a, "r": r, "v": v}
    gq = s[:, 6:9] @ C.T
    full = highpass(np.concatenate([a, r, v, gq], 1), hp, rate)
    ch = {"a": full[:, 0:3], "r": full[:, 3:6], "v": full[:, 6:9], "g": full[:, 9:12]}
    energy = np.linalg.norm(ch["r"], axis=1) + 5 * np.linalg.norm(ch["a"], axis=1)
    base = np.concatenate([ch[c] for c in channels], 1)
    if trim:
        rg = active_range(energy, rate, thr, smooth, padsec)
        if rg is not None: base = base[rg[0]:rg[1] + 1]
    out = [base]
    if deriv: out.append(np.gradient(base, axis=0) * rate / 20)
    if mags: out += [np.linalg.norm(base[:, g:g + 3], axis=1, keepdims=True) for g in range(0, base.shape[1], 3)]
    for e in extra:
        if e == "gravity_tilt": out.append(np.repeat(s[:rc, 6:9].mean(0)[None], len(base), 0))
    x = np.concatenate(out, 1).astype(np.float32)
    if norm == "global": x = x / (np.sqrt((x ** 2).mean()) + 1e-9)
    elif norm == "global+e":
        rms = np.sqrt((x ** 2).mean()) + 1e-9
        x = np.concatenate([x / rms, np.full((len(x), 1), np.log(rms), np.float32)], 1)
    elif norm == "chan": x = (x - x.mean(0)) / (x.std(0) + 1e-9)
    return x


def active_range(energy, rate, thr, smooth, padsec):
    minf = max(6, int(0.24 * rate)); pad = max(0, int(np.floor(padsec * rate + 0.5)))
    if len(energy) <= minf + 2: return None
    rad = max(0, int(np.floor(smooth * rate / 2 + 0.5)))
    sm = np.array([energy[max(0, i - rad):min(len(energy), i + rad + 1)].mean() for i in range(len(energy))])
    srt = np.sort(sm); floor, peak = srt[len(srt) // 5], srt[-1]
    if peak <= floor * 1.5: return None
    th = floor + thr * (peak - floor); idx = np.where(sm > th)[0]
    if len(idx) == 0: return None
    lo, hi = max(0, idx[0] - pad), min(len(energy) - 1, idx[-1] + pad)
    return (lo, hi) if hi - lo + 1 >= minf else None


def build(takes, key, **kw):
    """Adds takes[i][key]; falls back to the Swift features when a take has no raw samples."""
    for t in takes:
        if key in t: continue
        x = extract(t["raw"], t["t"], **kw) if "raw" in t else None
        t[key] = x if x is not None and len(x) >= 4 else None
    return key


def rand_R(rng, deg):
    a = rng.normal(size=3); a /= np.linalg.norm(a); th = np.radians(rng.uniform(-deg, deg))
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K


def build_aug(takes, key, V=16, deg=20, gain=(0.6, 1.4), seed=0, **kw):
    """takes[i][key+'_aug'] = list of V variants: raw frame re-seated by a random rotation up to `deg`
    (before gravity canonicalisation, as a real re-seat) and motion scaled by a log-uniform gain."""
    build(takes, key, **kw)
    rng = np.random.default_rng(seed)
    for t in takes:
        if key + "_aug" in t: continue
        vs = []
        if "raw" in t:
            for _ in range(V):
                g = float(np.exp(rng.uniform(np.log(gain[0]), np.log(gain[1]))))
                x = extract(t["raw"], t["t"], R=rand_R(rng, deg), gain=g, **kw)
                if x is not None and len(x) >= 4: vs.append(x)
        t[key + "_aug"] = vs or [t[key]]
    return key
