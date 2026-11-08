ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
NW3 = "lambda ts: np.array([3.0 if t['night'] else 1.0 for t in ts])"
B = f"fast.Fast(xkey='arv', VD=9, weight_fn={NW})"
Q = [
 ("arv_nw8_rep", B, ARV),
 ("syn200_arv_nw8", f"synth.Synth({B}, n=200, keys=('arv',))", ARV),
 ("syn600_arv_nw3", f"synth.Synth(fast.Fast(xkey='arv', VD=9, weight_fn={NW3}), n=600, keys=('arv',))", ARV),
 ("syn600all_arv_nw8", f"synth.Synth({B}, n=600, keys=('arv',), sel=lambda t: True)", ARV),
 ("ens_arv_x", f"ens.Ens({B}, fast.Fast(weight_fn={NW}))", ARV),
 ("ens_arv_gru", f"ens.Ens({B}, fast.Fast(xkey='arv', VD=9, weight_fn={NW}, net=lambda d: nets.GRU(d)))", ARV),
]
Q = [
 ("rec_x_t30", "fast.Fast(rec=dict(tau_min=30, steps=150, lr=5e-4))"),
 ("rec_arv_nw8_t30", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, rec=dict(tau_min=30, steps=150, lr=5e-4))", ARV),
 ("rec_x_t60_s300", "fast.Fast(rec=dict(tau_min=60, steps=300, lr=5e-4))"),
 ("rec_x_t15_hi", "fast.Fast(rec=dict(tau_min=15, steps=200, lr=1e-3, replay=0.5))"),
] + Q
