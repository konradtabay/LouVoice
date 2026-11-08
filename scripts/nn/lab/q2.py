R = {"raw": True}
def F(key, **kw): return dict(raw=True, setup=f"feats.build(takes,'{key}',**{kw!r})")
Q = [
 ("night_w3", "fast.Fast(weight_fn=lambda ts: np.array([3.0 if t['night'] else 1.0 for t in ts]))"),
 ("night_w8", "fast.Fast(weight_fn=lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts]))"),
 ("ft_night", "fast.Fast(ft=dict(sel=lambda t: t['night'], epochs=40, lr=5e-4, replay=1.0))"),
 ("ft_night_hi", "fast.Fast(ft=dict(sel=lambda t: t['night'], epochs=80, lr=1e-3, replay=0.5))"),
 ("norm_global", "fast.Fast(xkey='ng')", F('ng', norm='global')),
 ("nocanon", "fast.Fast(xkey='nc')", F('nc', canon=False)),
 ("r_only", "fast.Fast(xkey='ro', VD=3)", F('ro', channels=('r',))),
 ("deriv", "fast.Fast(xkey='dv')", F('dv', deriv=True)),
 ("hp04", "fast.Fast(xkey='hp4')", F('hp4', hp=0.4)),
 ("hp15", "fast.Fast(xkey='hp15')", F('hp15', hp=1.5)),
 ("loosetrim", "fast.Fast(xkey='lt', T=64)", F('lt', thr=0.2, padsec=0.2)),
 ("arv_mags_all", "fast.Fast(xkey='arvm', VD=9)", F('arvm', channels=('a','r','v'))),
]
def A(key, **kw): return dict(raw=True, setup=f"feats.build_aug(takes,'{key}',**{kw!r})")
Q += [
 ("phys20", "fast.Fast(xkey='pa', xaug=True, rotdeg=0, gain=(1,1))", A('pa', V=16, deg=20, gain=(0.6, 1.4))),
 ("phys35", "fast.Fast(xkey='pb', xaug=True, rotdeg=0, gain=(1,1))", A('pb', V=16, deg=35, gain=(0.6, 1.4))),
 ("phys20_keepaug", "fast.Fast(xkey='pc', xaug=True)", A('pc', V=16, deg=20, gain=(0.6, 1.4))),
 ("physgain", "fast.Fast(xkey='pd', xaug=True, rotdeg=0, gain=(1,1))", A('pd', V=16, deg=0.001, gain=(0.5, 1.5))),
]
