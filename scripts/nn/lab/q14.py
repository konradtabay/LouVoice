NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
Q = [
 ("proto_x", f"proto.Proto(weight_fn={NW})"),
 ("proto_arv", f"proto.Proto(xkey='arv', VD=9, weight_fn={NW})", ARV),
 ("proto_arv_b03", f"proto.Proto(xkey='arv', VD=9, weight_fn={NW}, blend=0.3, recent_k=10)", ARV),
]
