Q = [
 ("nosent", "fast.Fast(filt=lambda t: not t['block'].startswith('sentence'))"),
 ("noquiz", "fast.Fast(filt=lambda t: not t['quiz'])"),
 ("onlyenroll_cal", "fast.Fast(filt=lambda t: t['block'].split('-')[0] in ('enroll','calibrate','quiz'))"),
 ("gru", "fast.Fast(net=lambda d: nets.GRU(d))"),
 ("trans", "fast.Fast(net=lambda d: nets.Trans(d, T=48))"),
 ("rescnn128", "fast.Fast(net=lambda d: nets.ResCNN(d))"),
 ("cnn_w128", "fast.Fast(w=128)"),
 ("cnn_w32", "fast.Fast(w=32)"),
 ("cnn_drop5", "fast.Fast(drop=0.5, wd=5e-2)"),
 ("members7", "fast.Fast(members=7)"),
 ("T64", "fast.Fast(T=64)"),
 ("tta8", "fast.Fast(tta=8)"),
 ("lr1e-3_ep200", "fast.Fast(lr=1e-3, epochs=200)"),
]
def F(key, **kw): return dict(raw=True, setup=f"feats.build(takes,'{key}',**{kw!r})")
def A(key, **kw): return dict(raw=True, setup=f"feats.build_aug(takes,'{key}',**{kw!r})")
Q += [
 ("normE", "fast.Fast(xkey='ne')", F('ne', norm='global+e')),
 ("normE_gainwide", "fast.Fast(xkey='ne2', gain=(0.4,1.6))", F('ne2', norm='global+e')),
 ("gain04", "fast.Fast(gain=(0.4,1.5))"),
 ("phys_gain04_normE", "fast.Fast(xkey='pe', xaug=True, rotdeg=0, gain=(1,1))", A('pe', V=16, deg=20, gain=(0.4, 1.5), norm='global+e')),
]
import json as _j
OOF = "__import__('json').load(open('oof.json'))"
NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
Q += [
 ("clean05", f"fast.Fast(filt=(lambda o: lambda t: o.get(t['id'],1) >= 0.05)({OOF}))"),
 ("clean10", f"fast.Fast(filt=(lambda o: lambda t: o.get(t['id'],1) >= 0.10)({OOF}))"),
 ("arv_nw8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW})", ARV),
 ("arv_nw8_clean05", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, filt=(lambda o: lambda t: o.get(t['id'],1) >= 0.05)({OOF}))", ARV),
 ("arv_nw16", f"fast.Fast(xkey='arv', VD=9, weight_fn=lambda ts: np.array([16.0 if t['night'] else 1.0 for t in ts]))", ARV),
]
Q = Q[-5:] + Q[:-5]
Q = [("base2", "fast.Fast()"),
     ("hp15_arv_nw8", f"fast.Fast(xkey='hpa', VD=9, weight_fn={NW})", dict(raw=True, setup="feats.build(takes,'hpa',channels=('a','r','v'),hp=1.5)")),
    ] + Q
Q = Q[:2] + [("pseudo_conf", "pseudo.Pseudo(fast.Fast(members=2), fast.Fast())", {"flags": ["--keep-confirmed"]})] + Q[2:]
Q = Q[:3] + [
 ("run30", "fast.Fast(xkey='x_run')", dict(setup="running.build(takes)")),
 ("run30_scalar", "fast.Fast(xkey='xr1')", dict(setup="running.build(takes, out='xr1', scalar=True)")),
] + Q[3:]
