"""Agent Sock Python server: publish latency/throughput. Usage: bench_py.py <pkgroot> [--no-fsync]"""
import asyncio, os, sys, subprocess, tempfile, time, statistics, shutil, json
root = sys.argv[1]; extra = sys.argv[2:]
sys.path.insert(0, root)
from agent_sock.client import Client

def start(tmp):
    sock = os.path.join(tmp, "s.sock")
    p = subprocess.Popen([sys.executable, "-m", "agent_sock.server", "--sock", sock,
                          "--data-dir", os.path.join(tmp, "d")] + extra,
                         env=dict(os.environ, PYTHONPATH=root), cwd=root,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(200):
        if os.path.exists(sock): break
        time.sleep(0.05)
    return p, sock

async def run(sock):
    c = Client(agent_id="lat", sock_path=sock); await c.connect()
    await c.declare("b", "workqueue")
    lat = []
    for i in range(500):
        t = time.perf_counter(); await c.publish("b", f"l{i}", "x" * 200); lat.append(time.perf_counter() - t)
    lat.sort()
    cs = []
    for k in range(16):
        x = Client(agent_id=f"t{k}", sock_path=sock); await x.connect(); cs.append(x)
    N = 200
    async def worker(k, x):
        for i in range(N):
            await x.publish("b", f"t{k}-{i}", "x" * 200)
    t = time.perf_counter()
    await asyncio.gather(*(worker(k, x) for k, x in enumerate(cs)))
    dt = time.perf_counter() - t
    return {"p50_ms": lat[len(lat)//2]*1e3, "p99_ms": lat[int(len(lat)*.99)]*1e3,
            "seq_ops_s": len(lat)/sum(lat), "conc16_ops_s": 16*N/dt}

tmp = tempfile.mkdtemp()
p, sock = start(tmp)
try:
    r = asyncio.run(run(sock))
finally:
    p.kill(); p.wait(); shutil.rmtree(tmp, ignore_errors=True)
print(json.dumps({k: round(v, 3) for k, v in r.items()}))
