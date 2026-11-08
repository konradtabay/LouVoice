NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
Q = [
 ("tn32_x", "fast.Fast(xkey='x_n32', T=36, warp=(0.9,1.1))", dict(setup="tnorm.build(takes)")),
 ("tn32_x_nw8", f"fast.Fast(xkey='x_n32', T=36, warp=(0.9,1.1), weight_fn={NW})", dict(setup="tnorm.build(takes)")),
 ("tn32_arv_nw8", f"fast.Fast(xkey='arv_n32', VD=9, T=36, warp=(0.9,1.1), weight_fn={NW})", dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v')); tnorm.build(takes,'arv')")),
 ("tn32_x_nowarp", "fast.Fast(xkey='x_n32', T=32, warp=(1,1))", dict(setup="tnorm.build(takes)")),
]
