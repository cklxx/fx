"""Zig asock-server publish latency/throughput via the Python client. Usage: bench_zig.py <server-bin> <pkgroot> [--no-fsync]"""
import asyncio, os, sys, subprocess, tempfile, time, json, shutil
binp=sys.argv[1]; root=sys.argv[2]; extra=sys.argv[3:]
sys.path.insert(0, root)
from agent_sock.client import Client
tmp=tempfile.mkdtemp(); os.makedirs(os.path.join(tmp,".agent-sock"))
sock=os.path.join(tmp,".agent-sock","agent.sock")
p=subprocess.Popen([binp]+extra,cwd=tmp,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
while not os.path.exists(sock): time.sleep(0.05)
async def run():
    c=Client(agent_id="lat",sock_path=sock); await c.connect()
    lat=[]
    for i in range(500):
        t=time.perf_counter(); await c.publish("task.dispatch",f"l{i}","x"*200); lat.append(time.perf_counter()-t)
    lat.sort()
    cs=[]
    for k in range(16):
        x=Client(agent_id=f"t{k}",sock_path=sock); await x.connect(); cs.append(x)
    N=200
    async def w(k,x):
        for i in range(N): await x.publish("task.dispatch",f"t{k}-{i}","x"*200)
    t=time.perf_counter(); await asyncio.gather(*(w(k,x) for k,x in enumerate(cs))); dt=time.perf_counter()-t
    return {"p50_ms":lat[250]*1e3,"p99_ms":lat[495]*1e3,"seq_ops_s":500/sum(lat),"conc16_ops_s":16*N/dt}
try: r=asyncio.run(run())
finally: p.kill(); p.wait(); shutil.rmtree(tmp,ignore_errors=True)
print(json.dumps({k:round(v,3) for k,v in r.items()}))
