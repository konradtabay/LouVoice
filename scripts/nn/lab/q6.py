ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
Q = [
 ("adabn_x", "fast.Fast(rec=dict(steps=0, adabn=True, K=40, alpha=0.5))"),
 ("adabn_x_full", "fast.Fast(rec=dict(steps=0, adabn=True, K=40, alpha=1.0))"),
 ("adabn_arv_nw8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, rec=dict(steps=0, adabn=True, K=40, alpha=0.5))", ARV),
 ("rec_adabn_x", "fast.Fast(rec=dict(tau_min=30, steps=150, lr=5e-4, adabn=True, K=40, alpha=0.5))"),
]
