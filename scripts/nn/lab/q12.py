NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
Q = [
 ("fit_arv_nw8_s05", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, fitmatch=dict(sigma=0.05, steps=150, lr=5e-4))", ARV),
 ("fit_arv_nw8_s10", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, fitmatch=dict(sigma=0.10, steps=150, lr=5e-4))", ARV),
 ("fit_x_s05", "fast.Fast(fitmatch=dict(sigma=0.05, steps=150, lr=5e-4))", dict(raw=True)),
 ("gtilt_arv_nw8", f"fast.Fast(xkey='arvt', VD=9, weight_fn={NW})", dict(raw=True, setup="feats.build(takes,'arvt',channels=('a','r','v'),extra=('gravity_tilt',))")),
]
