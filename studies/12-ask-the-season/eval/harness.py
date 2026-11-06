"""Text-to-SQL harness. The model call runs in a sandbox that can reach Amazon Bedrock but not this machine, so the
harness works in two halves:

    harness.py batch RUN PROMPT SPLIT [--ids L01,L02] [--budget 0.50]   writes the sandbox script for one batch
    harness.py ingest RUN result.json                                     appends the sandbox's records to runs/RUN.jsonl
    harness.py spend                                                       total Bedrock spend across every run

The batch script sends each question to Claude Haiku 4.5 (Bedrock Converse, global inference profile, temperature 0),
paces calls 6.5 s apart for the 10 requests/minute quota, gives each call 60 s and one retry, stops when the batch
budget is spent, and returns the raw text, token usage and latency of every call. Keep batches to about 10 questions:
the sandbox has a run-time limit, and a batch that hits it returns nothing although its calls were billed. Model output is never executed in the sandbox; score.py runs it locally
against season.db through the server's read-only guard.
"""
import argparse
import hashlib
import json
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import server  # noqa: E402

MODEL = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
PRICE_IN = 1.00 / 1e6    # USD per input token, Haiku 4.5 on-demand, global cross-Region profile
PRICE_OUT = 5.00 / 1e6   # USD per output token
HARD_BUDGET = 1.00       # USD, all runs together
RUNS = HERE / "runs"
SCRATCH = pathlib.Path(tempfile.gettempdir()) / "ask_the_season_batches"  # generated code, not kept


def render(prompt):
    con = server.connect()
    text = (HERE / "prompts" / f"{prompt}.txt").read_text()
    return text.replace("{schema}", server.schema_text(con)).replace("{notes}", server.schema_notes().strip()).strip()


def questions(split=None, ids=None):
    qs = [json.loads(line) for line in (HERE / "questions.jsonl").read_text().splitlines() if line.strip()]
    if split:
        qs = [q for q in qs if q["split"] == split]
    if ids:
        keep = set(ids)
        qs = [q for q in qs if q["id"] in keep]
    return qs


def fnv1a64(text):
    """Prompt fingerprint the sandbox can also compute (hashlib is blocked there)."""
    h = 0xcbf29ce484222325
    for byte in text.encode():
        h = ((h ^ byte) * 0x100000001b3) % 2 ** 64
    return format(h, "016x")


def spend():
    total, calls = 0.0, 0
    for f in sorted(RUNS.glob("*.jsonl")):
        for line in f.read_text().splitlines():
            r = json.loads(line)
            if "in" in r:
                total += r["in"] * PRICE_IN + r["out"] * PRICE_OUT
                calls += r.get("calls", 1)
    return total, calls


SANDBOX = '''import time
SYSTEM = {system}
QS = {qs}
MODEL = {model!r}
BUDGET_LEFT = {budget}
PIN, POUT, GAP = {pin!r}, {pout!r}, 6.5
recs, spent, last = [], 0.0, 0.0
for qid, q in QS:
    if spent >= BUDGET_LEFT:
        recs.append({{"id": qid, "skipped": "budget"}})
        continue
    r, err = None, None
    for attempt in range(1, 3):
        wait = GAP - (time.time() - last)
        if wait > 0:
            await asyncio.sleep(wait)
        last = time.time()
        try:
            r = await asyncio.wait_for(call_boto3(service_name="bedrock-runtime", operation_name="Converse",
                region_name="us-east-2",
                params={{"modelId": MODEL, "system": [{{"text": SYSTEM}}],
                        "messages": [{{"role": "user", "content": [{{"text": q}}]}}],
                        "inferenceConfig": {{"maxTokens": 700, "temperature": 0}}}}), timeout=60)
        except Exception as e:
            r, err = None, repr(e)[:300]
        if isinstance(r, dict) and "output" in r:
            break
        err = err or str(r)[:300]
        r = None
        await asyncio.sleep(5)
    wall = time.time() - last
    if r is None:
        recs.append({{"id": qid, "error": err}})
        continue
    u = r["usage"]
    spent += u["inputTokens"] * PIN + u["outputTokens"] * POUT
    recs.append({{"id": qid, "text": r["output"]["message"]["content"][0]["text"], "in": u["inputTokens"],
                 "out": u["outputTokens"], "latency_ms": r["metrics"]["latencyMs"], "wall_ms": round(wall * 1000),
                 "stop": r["stopReason"], "attempt": attempt}})
h = 0xcbf29ce484222325
for byte in SYSTEM.encode():
    h = ((h ^ byte) * 0x100000001b3) % 2 ** 64
result = {{"system_fnv1a64": format(h, "016x"), "model": MODEL, "spent": spent, "records": recs}}
result
'''


def cmd_batch(a):
    total, _ = spend()
    budget = min(a.budget, HARD_BUDGET - total)
    if budget <= 0:
        raise SystemExit(f"hard budget reached: ${total:.4f} of ${HARD_BUDGET:.2f} spent")
    system = render(a.prompt)
    qs = questions(a.split, a.ids.split(",") if a.ids else None)
    code = SANDBOX.format(system=json.dumps(system), qs=json.dumps([[q["id"], q["question"]] for q in qs]),
                          model=MODEL, budget=round(budget, 4), pin=PRICE_IN, pout=PRICE_OUT)
    SCRATCH.mkdir(parents=True, exist_ok=True)
    out = SCRATCH / f"{a.run}_{qs[0]['id']}.py"
    out.write_text(code)
    meta = {"run": a.run, "prompt": a.prompt, "split": a.split, "ids": [q["id"] for q in qs],
            "system_sha256": hashlib.sha256(system.encode()).hexdigest(), "system_fnv1a64": fnv1a64(system)}
    (SCRATCH / f"{a.run}_{qs[0]['id']}.meta.json").write_text(json.dumps(meta))
    print(f"{out}  ({len(qs)} questions, system prompt {len(system)} chars, sha {meta['system_sha256'][:12]}, "
          f"fnv {meta['system_fnv1a64']}, batch budget ${budget:.4f}, spent so far ${total:.4f})")


def cmd_ingest(a):
    res = json.loads(pathlib.Path(a.result).read_text())
    res = res.get("return_value", res)
    metas = [json.loads(p.read_text()) for p in SCRATCH.glob(f"{a.run}_*.meta.json")]
    ids = {r["id"] for r in res["records"]}
    meta = next(m for m in metas if set(m["ids"]) == ids)
    if res["system_fnv1a64"] != meta["system_fnv1a64"]:
        raise SystemExit("system prompt hash mismatch: the sandbox did not send the rendered prompt")
    RUNS.mkdir(exist_ok=True)
    with open(RUNS / f"{a.run}.jsonl", "a") as f:
        for r in res["records"]:
            f.write(json.dumps({"run": a.run, "prompt": meta["prompt"], "model": res["model"],
                                "system_sha256": meta["system_sha256"], **r}) + "\n")
    total, calls = spend()
    print(f"ingested {len(res['records'])} records into runs/{a.run}.jsonl; total spend ${total:.4f} over {calls} calls")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("batch")
    b.add_argument("run"); b.add_argument("prompt"); b.add_argument("split")
    b.add_argument("--ids"); b.add_argument("--budget", type=float, default=0.30)
    i = sub.add_parser("ingest")
    i.add_argument("run"); i.add_argument("result")
    sub.add_parser("spend")
    a = p.parse_args()
    if a.cmd == "batch":
        cmd_batch(a)
    elif a.cmd == "ingest":
        cmd_ingest(a)
    else:
        total, calls = spend()
        print(f"${total:.4f} over {calls} calls (hard budget ${HARD_BUDGET:.2f})")


if __name__ == "__main__":
    main()
