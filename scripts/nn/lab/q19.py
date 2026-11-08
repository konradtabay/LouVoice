NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
S = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v')); spec.build(takes,'arv')")
Q = [
 ("spec_arv_nw8", f"fast.Fast(xkey='arv_spec8', VD=0, rotdeg=0, T=24, weight_fn={NW})", S),
 ("ens_arv_spec", f"ens.Ens(fast.Fast(xkey='arv', VD=9, weight_fn={NW}), fast.Fast(xkey='arv_spec8', VD=0, rotdeg=0, T=24, weight_fn={NW}))", S),
]
