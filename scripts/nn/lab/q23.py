ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
Q = [
 ("deep6_arv_nw8", f"fast.Fast(xkey='arv', VD=9, layers=6, weight_fn={NW})", ARV),
 ("deep6_arv_nw8_T64", f"fast.Fast(xkey='arv', VD=9, layers=6, T=64, weight_fn={NW})", ARV),
]
