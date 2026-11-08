"""Strict evaluation harness for the single-word model (word mode: hello can you hear me + _none).

Split is frozen in split.json (see its _doc). Rules:
- DEV score (what experiments are selected on): for each of the 3 late-night dev blocks, train on
  everything except that block and the LOCKED blocks, test on that block. Pooled accuracy over 52 takes.
- LOCKED score: train on everything except the LOCKED blocks, test on the 60 LOCKED takes.
  Only through `locked()`, which appends every look to locked_log.jsonl. Never select on it.
- Accuracy = exact top-1 over the 6 classes; answering `_none` for a word counts as wrong.
"""
import json, os, time, hashlib
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("LV_DATA", "/private/tmp/claude-501/-Users-konradtabay--claude-spares-spare-JzcJfu/78151fbc-ef4b-420d-852c-479fc23ce007/scratchpad/ml")
SPLIT = json.load(open(os.path.join(HERE, "split.json")))
WORDS = SPLIT["words"]; NONE = "_none"; LABELS = WORDS + [NONE]
assert hashlib.sha256(json.dumps(SPLIT["locked_ids"]).encode()).hexdigest() == SPLIT["locked_sha256"], "split.json was edited"
LOCKED_IDS = set(SPLIT["locked_ids"]); LOCKED_BLOCKS = set(SPLIT["locked_blocks"])

_cache = {}
# 2026-11-07 22:00 local in Apple reference-date seconds: the late-night fit starts here.
NIGHT_START = 815799600  # local time on this Mac


AUX = False   # set True to also load the other trained words as extra classes (y >= 6); never tested on
AUX_LABELS = ["are", "how", "is", "konrad", "my", "name", "today"]


def load(raw=False):
    """Every isolated word take with label in LABELS. x = Swift pipeline features (25 Hz, 8 dims).
    raw=True adds 'raw': (n, 16) array of r(3) a(3) g(3) q(4) p(3) at the sensor rate, and 't'."""
    key = ("raw" if raw else "feat") + ("+aux" if AUX else "")
    if key in _cache: return _cache[key]
    f = json.load(open(os.path.join(DATA, "features.json")))
    rawmap = {}
    tidx = os.path.join(DATA, "created.json")
    if not os.path.exists(tidx):
        d = json.load(open(os.path.join(DATA, "dataset.snapshot.json")))
        json.dump({t["id"]: t["createdAt"] for t in d["takes"]}, open(tidx, "w"))
    created = json.load(open(tidx))
    if raw:
        d = json.load(open(os.path.join(DATA, "dataset.snapshot.json")))
        for t in d["takes"]:
            s = t["samples"]
            if not s: continue
            rawmap[t["id"]] = (np.array([x["r"] + x["a"] + x["g"] + x["q"] + x["p"] for x in s], np.float32),
                               np.array([x["t"] for x in s], np.float64), t["createdAt"])
    takes = []
    for t in f["takes"]:
        if t["label"] not in LABELS and not (AUX and t["label"] in AUX_LABELS): continue
        x = np.asarray(t["values"], np.float32).reshape(-1, t["dims"])
        if len(x) < 4: continue
        d = dict(id=t["id"], label=t["label"], y=LABELS.index(t["label"]) if t["label"] in LABELS else 6 + AUX_LABELS.index(t["label"]), block=t["block"], quiz=t["test"], x=x,
                 created=created[t["id"]], night=created[t["id"]] >= NIGHT_START)
        if raw and t["id"] in rawmap:
            d["raw"], d["t"], _ = rawmap[t["id"]]
            o = np.argsort(d["t"]); d["grest"] = d["raw"][o][:15, 6:9].mean(0)
        takes.append(d)
    _cache[key] = takes
    return takes


def _acc(pred, takes):
    return float(np.mean([p == t["y"] for p, t in zip(pred, takes)]))


def _pool(takes, exclude_blocks, drop_confirmed):
    return [t for t in takes if t["block"] not in exclude_blocks and t["block"] not in LOCKED_BLOCKS
            and not (drop_confirmed and t["block"].startswith("confirmed"))]


def dev(fit, name="", raw=False, drop_confirmed=True, seed=0, verbose=True):
    """fit(train_takes, seed) -> predict(takes) -> (n, 6) probabilities. Returns pooled dev accuracy."""
    takes = load(raw); preds, tests = [], []
    for b in SPLIT["dev_blocks"]:
        test = [t for t in takes if t["block"] == b and t["label"] in WORDS]
        model = fit(_pool(takes, {b}, drop_confirmed), seed)
        preds += list(np.argmax(model(test), 1)); tests += test
    acc = _acc(preds, tests)
    per = {w: np.mean([p == t["y"] for p, t in zip(preds, tests) if t["label"] == w]) for w in WORDS}
    nonepred = np.mean([p == LABELS.index(NONE) for p in preds])
    if verbose:
        print(f"DEV {name}: {acc*100:.1f}% ({sum(p == t['y'] for p, t in zip(preds, tests))}/{len(tests)})  "
              + " ".join(f"{w}={v*100:.0f}" for w, v in per.items()) + f"  said_none={nonepred*100:.0f}%", flush=True)
    with open(os.path.join(HERE, "dev_log.jsonl"), "a") as fh:
        if name != "search": fh.write(json.dumps(dict(time=time.strftime("%H:%M:%S"), name=name, dev=acc, per=per)) + "\n")
    return acc


def none_check(fit, raw=False, seed=0):
    """Secondary: leave-one-block-out over blocks that contain _none takes, share of _none rejected
    and share of word takes in those blocks right. Daytime data (there is almost no late-night _none)."""
    takes = load(raw); blocks = sorted({t["block"] for t in takes if t["label"] == NONE and t["block"] not in LOCKED_BLOCKS})
    rej, n = 0, 0
    for b in blocks:
        test = [t for t in takes if t["block"] == b and t["label"] == NONE]
        p = np.argmax(fit(_pool(takes, {b}, False), seed)(test), 1)
        rej += int(np.sum(p == LABELS.index(NONE))); n += len(test)
    print(f"NONE rejected {rej}/{n} = {rej/max(n,1)*100:.0f}%", flush=True)
    return rej / max(n, 1)


def locked(fit, name, raw=False, drop_confirmed=True, seed=0):
    takes = load(raw)
    test = [t for t in takes if t["id"] in LOCKED_IDS]
    assert len(test) == 60
    p = np.argmax(fit(_pool(takes, set(), drop_confirmed), seed)(test), 1)
    acc = _acc(p, test)
    per = {w: float(np.mean([a == t["y"] for a, t in zip(p, test) if t["label"] == w])) for w in WORDS}
    with open(os.path.join(HERE, "locked_log.jsonl"), "a") as fh:
        fh.write(json.dumps(dict(time=time.strftime("%Y-%m-%d %H:%M:%S"), name=name, locked=acc, per=per)) + "\n")
    print(f"LOCKED {name}: {acc*100:.1f}% ({int(round(acc*60))}/60) " + " ".join(f"{w}={v*100:.0f}" for w, v in per.items()), flush=True)
    return acc


XS_SESSIONS = ["20261107-135739", "20261107-141846", "20261107-143436"]


def xsess(fit, name="", raw=False, seed=0, verbose=True, drop_confirmed=True):
    """Cross-session (daytime): for each of 3 day sessions, train without ANY block of that session
    (and without LOCKED / confirmed), test on that session's quiz takes of the 5 words. 55 takes."""
    takes = load(raw); preds, tests = [], []
    for s in XS_SESSIONS:
        test = [t for t in takes if s in t["block"] and t["quiz"] and t["label"] in WORDS]
        train = [t for t in _pool(takes, set(), drop_confirmed) if s not in t["block"]]
        preds += list(np.argmax(fit(train, seed)(test), 1)); tests += test
    acc = _acc(preds, tests)
    if verbose: print(f"XS {name}: {acc*100:.1f}% ({sum(p == t['y'] for p, t in zip(preds, tests))}/{len(tests)})", flush=True)
    return acc
