"""Run a queue of experiments P at a time:  python q.py queue_file.py [P]
queue file defines Q = [(name, expr, {"raw": bool, "setup": str, "seeds": "0,1", "flags": [...]}), ...]"""
import sys, subprocess, os
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__)); os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
ns = {}; exec(open(sys.argv[1]).read(), ns); Q = ns["Q"]; P = int(sys.argv[2]) if len(sys.argv) > 2 else 3
def run(item):
    name, expr, o = item if len(item) == 3 else (*item, {})
    cmd = [sys.executable, os.path.join(HERE, "run.py"), name, expr, "--seeds", o.get("seeds", "0,1")]
    if o.get("raw"): cmd.append("--raw")
    if o.get("setup"): cmd += ["--setup", o["setup"]]
    cmd += o.get("flags", []) + ([] if o.get("noxs") else ["--xs"])
    with open(os.path.join(HERE, "logs", name + ".log"), "w") as fh:
        subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT, cwd=HERE)
    last = open(os.path.join(HERE, "logs", name + ".log")).read().strip().splitlines()
    print(last[-1] if last else name + ": no output", flush=True)
with ThreadPoolExecutor(P) as ex: list(ex.map(run, Q))
