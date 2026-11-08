NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
Q = [
 ("al_x", "fast.Fast(xkey='x_al')", dict(setup="align.build(takes)")),
 ("al_x_nw8", f"fast.Fast(xkey='x_al', weight_fn={NW})", dict(setup="align.build(takes)")),
 ("al_arv_nw8", f"fast.Fast(xkey='arv_al', VD=9, weight_fn={NW})", dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v')); align.build(takes,'arv',groups=(0,3,6),rgroup=3)")),
 ("al_x_max25", "fast.Fast(xkey='xal25')", dict(setup="align.build(takes, out='xal25', maxdeg=25)")),
]
