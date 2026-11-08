"""Alternative networks with the CNN's interface: forward(x (B,T,D), mask (B,T)) -> logits (B,6)."""
import torch, torch.nn as nn, torch.nn.functional as F


def pool(h, mask):
    m = mask.unsqueeze(2)
    avg = (h * m).sum(1) / m.sum(1).clamp(min=1); mx = (h + (m - 1) * 1e4).amax(1)
    return torch.cat([avg, mx, mask.sum(1, keepdim=True) / 50.0], 1)


class GRU(nn.Module):
    def __init__(self, d, k=6, w=64, drop=0.3, layers=2):
        super().__init__()
        self.inp = nn.Linear(d, w); self.rnn = nn.GRU(w, w, layers, batch_first=True, bidirectional=True, dropout=drop)
        self.drop = nn.Dropout(drop); self.head = nn.Linear(4 * w + 1, k)

    def forward(self, x, mask):
        h, _ = self.rnn(F.gelu(self.inp(x)))
        return self.head(self.drop(pool(h, mask)))


class Trans(nn.Module):
    def __init__(self, d, k=6, w=64, drop=0.2, layers=3, T=96):
        super().__init__()
        self.inp = nn.Conv1d(d, w, 5, padding=2); self.pos = nn.Parameter(torch.zeros(1, T, w))
        el = nn.TransformerEncoderLayer(w, 4, 2 * w, drop, batch_first=True, activation="gelu", norm_first=True)
        self.enc = nn.TransformerEncoder(el, layers); self.drop = nn.Dropout(drop); self.head = nn.Linear(2 * w + 1, k)

    def forward(self, x, mask):
        h = F.gelu(self.inp(x.transpose(1, 2))).transpose(1, 2) + self.pos[:, :x.shape[1]]
        h = self.enc(h, src_key_padding_mask=mask < 0.5)
        return self.head(self.drop(pool(h, mask)))


class ResCNN(nn.Module):
    """Wider/deeper residual CNN with squeeze-excitation and stride-free dilations."""
    def __init__(self, d, k=6, w=128, drop=0.3, layers=6):
        super().__init__()
        dil = [1, 1, 2, 4, 8, 1, 2, 4][:layers]
        self.stem = nn.Conv1d(d, w, 5, padding=2); self.sn = nn.BatchNorm1d(w)
        self.convs = nn.ModuleList([nn.Conv1d(w, w, 3, padding=dl, dilation=dl) for dl in dil])
        self.norms = nn.ModuleList([nn.BatchNorm1d(w) for _ in dil])
        self.se = nn.ModuleList([nn.Sequential(nn.Linear(w, w // 8), nn.GELU(), nn.Linear(w // 8, w), nn.Sigmoid()) for _ in dil])
        self.drop = nn.Dropout(drop); self.head = nn.Linear(2 * w + 1, k)

    def forward(self, x, mask):
        h = F.gelu(self.sn(self.stem(x.transpose(1, 2))))
        for c, n, se in zip(self.convs, self.norms, self.se):
            y = F.gelu(n(c(h))); y = y * se(y.mean(2)).unsqueeze(2); h = h + y
        return self.head(self.drop(pool(h.transpose(1, 2), mask)))
