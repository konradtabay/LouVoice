NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
Q = [
 ("aux_x", "fast.Fast()", dict(setup="H.AUX = True; H._cache.clear()")),
 ("aux_arv_nw8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW})", dict(raw=True, setup="H.AUX = True; H._cache.clear(); takes = H.load(True); feats.build(takes,'arv',channels=('a','r','v'))")),
]
