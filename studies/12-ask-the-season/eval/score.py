"""Scores saved model outputs by execution: each predicted query runs locally against season.db through the same
read-only guard as the MCP server, and its result is compared with the gold result.

    .venv/bin/python3 studies/12-ask-the-season/eval/score.py            # scores every run in eval/runs/
    .venv/bin/python3 studies/12-ask-the-season/eval/score.py --selftest # scores the gold SQL itself (must be 100%)

Matching rules (fixed before any model output was scored):
- The query is the last code block in the reply. A last block that holds only CANNOT_ANSWER, or a reply with no
  block that contains CANNOT_ANSWER, is a refusal.
- Rows are compared as multisets unless the question asks for an order. Row counts must be equal.
- Each gold column must map to a distinct predicted column; extra predicted columns are allowed.
- Integers must be equal. Other numbers match within presentation rounding: 0.051 or 0.5% for values of 1 or more,
  0.0051 or 1% below 1. Text matches case-insensitively after trimming.
- An unanswerable question is right only when the model replies CANNOT_ANSWER, or, where the question allows it,
  when the query returns no rows.
"""
import argparse
import csv
import itertools
import json
import math
import pathlib
import random
import re
import sys
from collections import Counter, defaultdict

HERE = pathlib.Path(__file__).resolve().parent
STUDY = HERE.parent
sys.path.insert(0, str(STUDY))
import server  # noqa: E402
from harness import PRICE_IN, PRICE_OUT  # noqa: E402

RESULTS = STUDY / "results"
CANNOT = "CANNOT_ANSWER"
PAIRS = [("baseline_dev", "improved_v1_dev"), ("baseline_dev", "improved_v2_dev"), ("baseline_test", "improved_test")]


# ---------------------------------------------------------------- parsing and matching

def parse_output(text):
    t = (text or "").strip()
    blocks = re.findall(r"```(?:sql|sqlite)?\s*\n?(.*?)```", t, re.S | re.I)
    if blocks:  # the last block: models sometimes write a query, notice a mistake and revise it
        last = blocks[-1].strip().rstrip(";").strip()
        return ("refuse", None) if last == CANNOT else ("sql", last)
    if CANNOT in t:
        return "refuse", None
    if re.match(r"\s*(SELECT|WITH)\b", t, re.I):
        return "sql", t.rstrip(";").strip()
    return "unparseable", None


def _num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        try:
            return float(v.strip())
        except ValueError:
            return None
    return None


def value_match(p, g):
    if g is None or p is None:
        return g is None and p is None
    gn, pn = _num(g), _num(p)
    if gn is not None and pn is not None and not isinstance(g, str):
        if float(gn).is_integer() and float(pn).is_integer():
            return int(gn) == int(pn)
        tol = max(0.051, 0.005 * abs(gn)) if abs(gn) >= 1 else max(0.0051, 0.01 * abs(gn))
        return math.isfinite(pn) and abs(pn - gn) <= tol
    return str(p).strip().lower() == str(g).strip().lower()


def rows_match(pred, gold, ordered, mapping):
    proj = [[r[mapping[j]] for j in range(len(mapping))] for r in pred]
    if ordered:
        return all(all(value_match(a, b) for a, b in zip(pr, gr)) for pr, gr in zip(proj, gold))
    left = list(proj)
    for gr in gold:  # greedy multiset match; gold answers are small
        hit = next((i for i, pr in enumerate(left) if all(value_match(a, b) for a, b in zip(pr, gr))), None)
        if hit is None:
            return False
        left.pop(hit)
    return True


def result_match(pred, gold, ordered=False):
    if len(pred) != len(gold):
        return False
    if not gold:
        return True
    ng, npred = len(gold[0]), len(pred[0])
    if npred < ng:
        return False
    # candidate predicted columns for each gold column: same values, ignoring order
    cands = []
    for j in range(ng):
        gcol = [r[j] for r in gold]
        ok = [k for k in range(npred) if rows_match([[r[k]] for r in pred], [[v] for v in gcol], ordered, [0])]
        if not ok:
            return False
        cands.append(ok)
    for combo in itertools.product(*cands):
        if len(set(combo)) == ng and rows_match(pred, gold, ordered, list(combo)):
            return True
    return False


def score_one(q, text, con):
    kind, sql = parse_output(text)
    out = {"kind": kind, "pred_sql": sql, "error": None, "pred_rows": None}
    unanswerable = q["gold_answer"] == CANNOT
    if kind == "refuse":
        out["outcome"] = "refused_correctly" if unanswerable else "refused_incorrectly"
        out["correct"] = unanswerable
        return out
    if kind == "unparseable":
        out["outcome"], out["correct"] = "unparseable", False
        return out
    res = server.run_readonly(con, sql, row_cap=1000)
    if "error" in res:
        out["error"] = res["error"]
        out["outcome"], out["correct"] = ("answered_unanswerable" if unanswerable else "sql_error"), False
        return out
    out["pred_rows"] = res["rows"][:10]
    if unanswerable:
        ok = q.get("accept_empty") and res["row_count"] == 0
        out["outcome"], out["correct"] = ("empty_result_accepted" if ok else "answered_unanswerable"), bool(ok)
        return out
    golds = [q["gold_answer"]] + q.get("accept_answers", [])
    ok = any(result_match(res["rows"], g, q.get("ordered", False)) for g in golds)
    out["outcome"], out["correct"] = ("correct" if ok else "wrong_result"), ok
    return out


# ---------------------------------------------------------------- statistics

def wilson(k, n, z=1.959964):
    if n == 0:
        return float("nan"), float("nan")
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return mid - half, mid + half


def mcnemar_exact(b, c):
    """Two-sided exact McNemar test: under H0 the b + c discordant pairs split as Binomial(b + c, 1/2)."""
    n = b + c
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, k) for k in range(0, min(b, c) + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def paired_bootstrap(diffs, reps=10_000, seed=20261105):
    """95% percentile interval for the mean paired difference, resampling questions."""
    rng = random.Random(seed)
    n = len(diffs)
    means = sorted(sum(rng.choice(diffs) for _ in range(n)) / n for _ in range(reps))
    return means[int(0.025 * reps)], means[int(0.975 * reps) - 1]


# ---------------------------------------------------------------- taxonomy

def auto_label(o):
    if o["outcome"] in ("refused_incorrectly", "answered_unanswerable", "unparseable"):
        return {"refused_incorrectly": "refused an answerable question",
                "answered_unanswerable": "answered an unanswerable question",
                "unparseable": "unparseable output"}[o["outcome"]]
    if o["outcome"] == "sql_error":
        e = o["error"] or ""
        if "no such column" in e:
            return "wrong column"
        if "no such table" in e:
            return "wrong table"
        return "sql error"
    return None


def load_labels():
    path = HERE / "failure_labels.csv"
    if not path.exists():
        return {}
    with open(path) as f:
        return {(r["run"], r["id"]): r for r in csv.DictReader(f)}


# ---------------------------------------------------------------- main

def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k) for k in fields})


def selftest(con, qs):
    bad = []
    for q in qs:
        text = CANNOT if q["gold_sql"] is None else f"```sql\n{q['gold_sql']}\n```"
        if not score_one(q, text, con)["correct"]:
            bad.append(q["id"])
    assert value_match(52.3, 52.31) and value_match(52, 52.31) is False and value_match(0.52, 0.523)
    assert not value_match(0, 0.43) and not value_match(313, 312) and value_match(312.0, 312)
    assert mcnemar_exact(0, 8) == 2 / 256 and mcnemar_exact(7, 9) > 0.8
    lo, hi = wilson(31, 48)
    assert 0.50 < lo < 0.51 and 0.76 < hi < 0.77
    print("selftest:", "ok" if not bad else f"gold failed for {bad}", f"({len(qs)} questions)")
    return not bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    con = server.connect()
    qs = {q["id"]: q for q in (json.loads(l) for l in (HERE / "questions.jsonl").read_text().splitlines() if l.strip())}
    if a.selftest:
        sys.exit(0 if selftest(con, list(qs.values())) else 1)

    labels = load_labels()
    per_q, outcomes = [], defaultdict(dict)
    for f in sorted((HERE / "runs").glob("*.jsonl")):
        run = f.stem
        if run.startswith("_"):
            continue
        for line in f.read_text().splitlines():
            r = json.loads(line)
            if "text" not in r:
                continue
            q = qs[r["id"]]
            o = score_one(q, r["text"], con)
            lab = auto_label(o)
            manual = labels.get((run, r["id"]))
            if manual:  # a hand label, where one exists, replaces the automatic one
                lab = manual["label"]
            elif o["outcome"] == "wrong_result":
                lab = "unlabeled"
            row = {"run": run, "id": r["id"], "split": q["split"], "category": q["category"], "correct": int(o["correct"]),
                   "outcome": o["outcome"], "failure": lab if not o["correct"] else "",
                   "note": manual["note"] if (manual and not o["correct"]) else "",
                   "in_tokens": r["in"], "out_tokens": r["out"],
                   "cost_usd": round(r["in"] * PRICE_IN + r["out"] * PRICE_OUT, 6),
                   "latency_ms": r["latency_ms"], "wall_ms": r["wall_ms"],
                   "pred_sql": o["pred_sql"], "error": o["error"],
                   "pred_rows": json.dumps(o["pred_rows"], default=str) if o["pred_rows"] is not None else ""}
            per_q.append(row)
            outcomes[run][r["id"]] = row
    write_csv(RESULTS / "eval_by_question.csv", per_q, list(per_q[0].keys()) if per_q else ["run"])

    summary = []
    for run, rows in outcomes.items():
        rs = list(rows.values())
        for subset, keep in (("all", lambda x: True), ("answerable", lambda x: x["category"] != "unanswerable"),
                             ("unanswerable", lambda x: x["category"] == "unanswerable")):
            sub = [x for x in rs if keep(x)]
            if not sub:
                continue
            k, n = sum(x["correct"] for x in sub), len(sub)
            lo, hi = wilson(k, n)
            lat = sorted(x["latency_ms"] for x in sub)
            summary.append({"run": run, "split": sub[0]["split"], "subset": subset, "n": n, "correct": k,
                            "accuracy": round(k / n, 4), "ci_low": round(lo, 4), "ci_high": round(hi, 4),
                            "cost_usd": round(sum(x["cost_usd"] for x in sub), 5),
                            "cost_per_question_usd": round(sum(x["cost_usd"] for x in sub) / n, 6),
                            "mean_in_tokens": round(sum(x["in_tokens"] for x in sub) / n, 1),
                            "mean_out_tokens": round(sum(x["out_tokens"] for x in sub) / n, 1),
                            "median_latency_ms": lat[len(lat) // 2], "max_latency_ms": lat[-1]})
    write_csv(RESULTS / "eval_summary.csv", summary, list(summary[0].keys()) if summary else ["run"])

    tests = []
    for base, new in PAIRS:
        if base not in outcomes or new not in outcomes:
            continue
        ids = sorted(set(outcomes[base]) & set(outcomes[new]))
        for subset in ("all", "answerable"):
            use = [i for i in ids if subset == "all" or qs[i]["category"] != "unanswerable"]
            b = sum(outcomes[base][i]["correct"] and not outcomes[new][i]["correct"] for i in use)
            c = sum(not outcomes[base][i]["correct"] and outcomes[new][i]["correct"] for i in use)
            d = [outcomes[new][i]["correct"] - outcomes[base][i]["correct"] for i in use]
            lo, hi = paired_bootstrap(d)
            tests.append({"baseline": base, "improved": new, "subset": subset, "n_paired": len(use),
                          "baseline_correct": sum(outcomes[base][i]["correct"] for i in use),
                          "improved_correct": sum(outcomes[new][i]["correct"] for i in use),
                          "lost": b, "gained": c, "mcnemar_exact_p": round(mcnemar_exact(b, c), 4),
                          "accuracy_gain": round(sum(d) / len(d), 4), "gain_ci_low": round(lo, 4),
                          "gain_ci_high": round(hi, 4)})
    write_csv(RESULTS / "mcnemar.csv", tests, list(tests[0].keys()) if tests else ["baseline"])

    tax = Counter((x["run"], x["failure"]) for x in per_q if not x["correct"])
    write_csv(RESULTS / "failure_taxonomy.csv",
              [{"run": r, "failure": f, "n": n} for (r, f), n in sorted(tax.items())], ["run", "failure", "n"])

    for s in summary:
        if s["subset"] == "all":
            print(f"{s['run']:<18} {s['correct']:>2}/{s['n']:<2} {s['accuracy']:.3f} "
                  f"[{s['ci_low']:.2f}, {s['ci_high']:.2f}]  ${s['cost_per_question_usd']:.5f}/q  "
                  f"median {s['median_latency_ms']} ms")
    for t in tests:
        print(f"{t['baseline']} vs {t['improved']} ({t['subset']}): lost {t['lost']}, gained {t['gained']}, "
              f"p = {t['mcnemar_exact_p']}, gain {t['accuracy_gain']:+.3f} [{t['gain_ci_low']:+.2f}, {t['gain_ci_high']:+.2f}]")
    unl = [(x["run"], x["id"]) for x in per_q if x["failure"] == "unlabeled"]
    if unl:
        print("unlabeled wrong results:", unl)


if __name__ == "__main__":
    main()
