#!/bin/bash
# canonical llama service bench: unique random prompts, pp x3 + tg x3
python3 - <<'PYEOF'
import subprocess,time,json,random
random.seed(int(time.time())&1023)
w=lambda: random.choice(["alpha","bravo","charlie","delta","echo","foxtrot","golf","hotel","india","juliet"])
ppl=[]; tgl=[]
for run in range(3):
    p=" ".join(w()+str(random.randint(0,999999)) for _ in range(1200))
    t=time.time()
    r=subprocess.run(["curl","-s","-m","300","localhost:8080/v1/completions","-d",json.dumps({"model":"ornith","prompt":p,"max_tokens":1})],capture_output=True)
    try:
        d=json.loads(r.stdout); ppl.append(d["usage"]["prompt_tokens"]/(time.time()-t))
    except Exception as e: ppl.append(-1)
for run in range(3):
    t=time.time()
    r=subprocess.run(["curl","-s","-m","300","localhost:8080/v1/completions","-d",json.dumps({"model":"ornith","prompt":"count numbers","max_tokens":120})],capture_output=True)
    try:
        d=json.loads(r.stdout); tgl.append(d["usage"]["completion_tokens"]/(time.time()-t))
    except Exception as e: tgl.append(-1)
print("pp tok/s:", " ".join("%.0f"%x for x in ppl))
print("tg tok/s:", " ".join("%.1f"%x for x in tgl))
PYEOF
