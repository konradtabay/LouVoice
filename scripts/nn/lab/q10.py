NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
S = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v')); tnorm.build(takes,'arv')")
ARV = f"fast.Fast(xkey='arv', VD=9, weight_fn={NW})"
TN = f"fast.Fast(xkey='arv_n32', VD=9, T=36, warp=(0.9,1.1), weight_fn={NW})"
X = "fast.Fast(members=5)"
XN = f"fast.Fast(weight_fn={NW})"
Q = [
 ("E_arv_x5", f"ens.Ens({ARV}, {X})", S),
 ("E_arv_tn_x5", f"ens.Ens({ARV}, {TN}, {X})", S),
 ("E_arv_tn_x5_xn", f"ens.Ens({ARV}, {TN}, {X}, {XN})", S),
 ("E_arv_tn", f"ens.Ens({ARV}, {TN})", S),
]
