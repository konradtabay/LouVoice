NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
def F(key, **kw): return dict(raw=True, setup=f"feats.build(takes,'{key}',**{kw!r})")
def M(key, VD, T=48, extra=""): return f"fast.Fast(xkey='{key}', VD={VD}, T={T}, weight_fn={NW}{extra})"
Q = [
 ("r_arv50", M('a50', 9, 96), F('a50', channels=('a','r','v'), rate=50)),
 ("r_arv_notrim", M('ant', 9, 80), F('ant', channels=('a','r','v'), trim=False)),
 ("r_arvg", M('arvg', 12), F('arvg', channels=('a','r','v','g'))),
 ("r_arv_hp04", M('a04', 9), F('a04', channels=('a','r','v'), hp=0.4)),
 ("r_arv_deriv", M('ad', 9), F('ad', channels=('a','r','v'), deriv=True)),
 ("r_arv_loosetrim", M('alt', 9, 64), F('alt', channels=('a','r','v'), thr=0.2, padsec=0.2)),
 ("r_arv_m7", M('arv', 9, extra=", members=7"), F('arv', channels=('a','r','v'))),
 ("r_ar", M('ar', 6), F('ar', channels=('a','r'))),
]
