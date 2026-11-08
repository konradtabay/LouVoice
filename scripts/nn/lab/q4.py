def F(key, **kw): return dict(raw=True, setup=f"feats.build(takes,'{key}',**{kw!r})")
NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
Q = [
 ("f_hp15", "fast.Fast(xkey='h15')", F('h15', hp=1.5)),
 ("f_arv", "fast.Fast(xkey='arv', VD=9)", F('arv', channels=('a','r','v'))),
 ("f_hp15_arv", "fast.Fast(xkey='h15a', VD=9)", F('h15a', hp=1.5, channels=('a','r','v'))),
 ("f_hp20_arv", "fast.Fast(xkey='h20a', VD=9)", F('h20a', hp=2.0, channels=('a','r','v'))),
 ("f_hp25_arv", "fast.Fast(xkey='h25a', VD=9)", F('h25a', hp=2.5, channels=('a','r','v'))),
 ("f_hp15_ar", "fast.Fast(xkey='h15ar', VD=6)", F('h15ar', hp=1.5, channels=('a','r'))),
 ("f_hp15_arv_nw8_ft", f"fast.Fast(xkey='h15a', VD=9, weight_fn={NW}, ft=dict(sel=lambda t: t['night'], epochs=80, lr=1e-3, replay=0.5))", F('h15a', hp=1.5, channels=('a','r','v'))),
 ("f_hp15_arv_ft", "fast.Fast(xkey='h15a', VD=9, ft=dict(sel=lambda t: t['night'], epochs=80, lr=1e-3, replay=0.5))", F('h15a', hp=1.5, channels=('a','r','v'))),
]
