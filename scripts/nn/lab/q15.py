NW = "lambda ts: np.array([8.0 if t['night'] else 1.0 for t in ts])"
ARV = dict(raw=True, setup="feats.build(takes,'arv',channels=('a','r','v'))")
OOF = "__import__('json').load(open('oof.json'))"
Q = [
 ("arv_nw8_nosent", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, filt=lambda t: not t['block'].startswith('sentence'))", ARV),
 ("arv_nw8_cleansent", f"fast.Fast(xkey='arv', VD=9, weight_fn={NW}, filt=(lambda o: lambda t: not (t['block'].startswith('sentence') and o.get(t['id'],1) < 0.05))({OOF}))", ARV),
 ("arv_nw8_sent_half", f"fast.Fast(xkey='arv', VD=9, weight_fn=lambda ts: np.array([(8.0 if t['night'] else 1.0) * (0.5 if t['block'].startswith('sentence') else 1.0) for t in ts]))", ARV),
]
