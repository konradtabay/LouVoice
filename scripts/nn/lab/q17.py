NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
Q = [
 ("snr_arv_nw8", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, snr=(0.5, 0.4, 0.8))", ARV),
 ("snr_arv_nw8_p3", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, snr=(0.3, 0.5, 0.9))", ARV),
 ("snr_x", "fast.Fast(snr=(0.5, 0.4, 0.8))"),
]
