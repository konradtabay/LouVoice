NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
Q = [
 ("mix_arv_nw8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, net=lambda d: nets.MixCNN(d))", ARV),
 ("mix_arv_nw8_p8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, net=lambda d: nets.MixCNN(d, p=0.8, alpha=0.3, layers_mix=3))", ARV),
 ("mix_x", "fast.Fast(net=lambda d: nets.MixCNN(d))"),
]
