"""Average the probabilities of several fits (each may read a different feature key)."""
import numpy as np


class Ens:
    def __init__(self, *fits, w=None):
        self.fits, self.w = fits, w

    def __call__(self, takes, seed=0):
        ps = [f(takes, seed) for f in self.fits]
        w = self.w or [1.0] * len(ps)
        return lambda test: sum(wi * p(test) for wi, p in zip(w, ps)) / sum(w)
