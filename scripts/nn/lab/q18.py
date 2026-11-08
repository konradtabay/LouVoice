NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
NW4 = "lambda ts: np.array([4.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
Q = [
 ("os_arv_nw8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, oversample=True)", ARV),
 ("os_arv_nw4", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW4}, oversample=True)", ARV),
]
