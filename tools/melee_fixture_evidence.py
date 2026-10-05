"""Check authoritative melee health deltas against independent observer state.

Each case pins target ID, damage type, expected deltas, and observer PNGs.
This reads runtime evidence; it does not synthesize hits or calculate damage.
"""
import argparse
import json
from pathlib import Path
import re
import struct

def rows(log, event):
    result=[]
    for line in log.splitlines():
        match=re.search(r"KF2VRNet " + event + r" (.*)",line)
        if match:
            result.append(dict(re.findall(r"([a-z_]+)=([^\s]+)",match.group(1))))
    return result

def png(path):
    try:
        p=Path(path);header=p.read_bytes()[:24]
        if len(header)!=24 or header[:8]!=b"\x89PNG\r\n\x1a\n" or header[12:16]!=b"IHDR":return False
        return all(struct.unpack(">II",header[16:24]))
    except OSError:return False

def analyze(server, observer, cases):
    damage=rows(server,"target_damage");states=rows(observer,"target_state")
    results=[]
    for case in cases:
        problems=[];actual=[];after=[]
        hits=[x for x in damage if x.get("target")==case["target"]]
        expected=case["expected_deltas"]
        if len(hits)!=len(expected):problems.append("authoritative receipt count differs")
        previous=None
        for index, hit in enumerate(hits):
            try:
                before=int(hit["before"]);health=int(hit["after"]);receipt=int(hit["receipt"])
                actual.append(before-health);after.append(health)
                if hit.get("netmode")!="1":problems.append("receipt is not dedicated authority")
                if hit.get("damage_type")!=case["damage_type"]:problems.append("wrong stock damage type")
                if receipt!=index+1:problems.append("receipt sequence differs")
                if previous is not None and before!=previous:problems.append("health chain differs")
                previous=health
                visible=[x for x in states if x.get("target")==case["target"] and x.get("receipt")==str(receipt)
                         and x.get("health")==str(health) and x.get("netmode")=="3"]
                if not visible:problems.append("independent observer health missing")
            except (KeyError,ValueError):problems.append("malformed damage receipt")
        if actual!=expected:problems.append("actual health deltas differ")
        if case.get("input")!="authored synthetic":problems.append("authored input scope missing")
        captures=case.get("observer_captures",[])
        if not captures or not all(png(p) for p in captures):problems.append("observer PNG missing or invalid")
        results.append({"target":case["target"],"expected_deltas":expected,"actual_deltas":actual,"health_after":after,
                        "passed":not problems,"problems":problems})
    return {"input":"authored synthetic; not physical tracked capture","passed":bool(results) and all(x["passed"] for x in results),"cases":results}

def read(path):
    b=Path(path).read_bytes()
    return b.decode("utf-16" if b.startswith((b"\xff\xfe",b"\xfe\xff")) else "utf-8-sig",errors="replace")

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server",required=True,type=Path);p.add_argument("--observer",required=True,type=Path)
    p.add_argument("--cases",required=True,type=Path);p.add_argument("--output",type=Path)
    a=p.parse_args();result=analyze(read(a.server),read(a.observer),json.loads(a.cases.read_text(encoding="utf-8")))
    text=json.dumps(result,indent=2)
    if a.output:a.output.write_text(text,encoding="utf-8")
    print(text);return 0 if result["passed"] else 1
if __name__=="__main__":raise SystemExit(main())
