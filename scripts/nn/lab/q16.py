NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
Q = [
 ("swa_arv_nw8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, swa=0.3)", ARV),
 ("swa_arv_nw8_ep150", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, swa=0.4, epochs=150)", ARV),
 ("swa_x", "fast.Fast(swa=0.3)"),
]
