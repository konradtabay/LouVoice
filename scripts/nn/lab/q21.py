ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))", seeds="2,3")
Q = [("confirm_common4_s23", "fast.Fast(xkey='arv', VD=9, wd=0.001, smooth=0.0, warp=(0.9,1.2), weight_fn=lambda ts: np.array([4.0 if t['night'] else 1.0 for t in ts]))", ARV)]
