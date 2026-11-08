Q = [
 ("base", "fast.Fast()"),
 ("rot30", "fast.Fast(rotdeg=30)"),
 ("yaw45", "fast.Fast(yawdeg=45)"),
 ("gainwide", "fast.Fast(gain=(0.5,1.6))"),
 ("changain", "fast.Fast(chan_gain=0.2)"),
 ("dropconf", "fast.Fast()", {"flags": ["--drop-confirmed"]}),
 ("ep200", "fast.Fast(epochs=200)"),
 ("tmask", "fast.Fast(time_mask=6)"),
 ("mixup", "fast.Fast(mixup=0.4)"),
 ("acc_arv", "fast.Fast(xkey='arv', VD=9)", {"raw": True, "setup": "feats.build(takes,'arv',channels=('a','r','v'))"}),
 ("rate50", "fast.Fast(xkey='r50', T=96)", {"raw": True, "setup": "feats.build(takes,'r50',rate=50)"}),
 ("notrim", "fast.Fast(xkey='nt', T=80)", {"raw": True, "setup": "feats.build(takes,'nt',trim=False)"}),
]
