Q = [
 ("nosent", "fast.Fast(filt=lambda t: not t['block'].startswith('sentence'))"),
 ("noquiz", "fast.Fast(filt=lambda t: not t['quiz'])"),
 ("onlyenroll_cal", "fast.Fast(filt=lambda t: t['block'].split('-')[0] in ('enroll','calibrate','quiz'))"),
 ("night_w3", "fast.Fast(weight_fn=lambda ts: np.array([3.0 if t['night'] else 1.0 for t in ts]))"),
 ("ft_night", "fast.Fast(ft=dict(sel=lambda t: t['night'], epochs=40, lr=5e-4, replay=1.0))"),
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
