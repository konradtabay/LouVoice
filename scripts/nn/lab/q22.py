ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
def sub(f): return f"lambda t: (hash(t['id']) % 1000) / 1000 < {f}"
Q = [(f"lc_{int(f*100)}", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, filt={sub(f)})", ARV) for f in (0.25, 0.5, 0.75)]
