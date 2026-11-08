ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))", seeds="2,3")
CAND = "fast.Fast(xkey='arv', VD=9, lr=0.003, wd=0.001, smooth=0.0, drop=0.5, w=96, T=56, epochs=100, rotdeg=12, jitter=0.06, bs=64, gain=(0.6,1.5), warp=(0.9,1.2), weight_fn=lambda ts: np.array([4.0 if t['night'] else 1.0 for t in ts]))"
SHIP = "fast.Fast(xkey='arv', VD=9, weight_fn=lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts]))"
Q = [("confirm_cand_s23", CAND, ARV), ("confirm_ship_s23", SHIP, ARV)]
