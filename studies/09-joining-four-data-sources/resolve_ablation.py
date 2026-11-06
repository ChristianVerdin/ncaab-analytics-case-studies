"""Replay the pipeline's KenPom/Barttorvik name resolver with parts of its cascade removed.

Imports the production resolver (fetch_kenpom.resolve_team_id) from the private pipeline, so this measures the
code that runs, not a re-implementation. Opens every database read-only. Writes team NAMES and counts only,
never ratings.

    NCAAB_PIPELINE_DIR=/path/to/ncaab_2027 python3 resolve_ablation.py <out_dir>
"""
import collections
import csv
import os
import random
import sqlite3
import sys

PIPE = os.environ.get("NCAAB_PIPELINE_DIR", os.path.expanduser("~/projects/ncaab_2027"))
sys.path.insert(0, os.path.join(PIPE, "scripts"))
import fetch_kenpom as fk  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
N_SHUFFLES = 500


def ro(path):
    return sqlite3.connect(f"file:{os.path.join(PIPE, path)}?mode=ro", uri=True)


live = ro("data/ncaab_analytics.db")
arch = ro("data/archive/ncaab_analytics_2026_final.db")
hist = ro("data/archive/kenpom_history_2026.db")

explicit_now, _ = fk.build_team_name_map(live)
explicit_old = {r[0]: r[1] for r in arch.execute(
    "SELECT api_team_name, db_team_id FROM team_name_mapping WHERE match_method = 'kenpom_manual'")}


def espn_universe(con):
    """The resolver's ESPN name map for that season's teams table, plus id -> (name, conference key or None)."""
    _, teams_map = fk.build_team_name_map(con)
    info = {str(r[0]): (r[1], r[2]) for r in con.execute("SELECT team_id, team_name, conference_id FROM teams")}
    return teams_map, info


ESPN_NOW, ESPN_LAST = espn_universe(live), espn_universe(arch)

# Each source's names with its own conference label, matched against that season's ESPN teams table
universes = {
    "KenPom 2026-27": (list(live.execute(
        "SELECT DISTINCT team_name, conference FROM kenpom_ratings WHERE season = 2027")), ESPN_NOW),
    "Barttorvik 2026-27": (list(live.execute(
        "SELECT DISTINCT team_name, conference FROM barttorvik_ratings WHERE season = 2027")), ESPN_NOW),
    "KenPom 2025-26": (list(hist.execute("SELECT team, MAX(conf) FROM kp_archive GROUP BY team")), ESPN_LAST),
}


def resolve(name, explicit, teams_map, fixes=True, fuzzy=True):
    """Production resolve_team_id, optionally without the hardcoded fixes or the fuzzy steps (4-5)."""
    if not fuzzy:
        if name in explicit:
            return explicit[name]
        if fixes and name in fk.KENPOM_NAME_FIXES and fk.KENPOM_NAME_FIXES[name] in teams_map:
            return teams_map[fk.KENPOM_NAME_FIXES[name]]
        return teams_map.get(name)
    saved = fk.KENPOM_NAME_FIXES
    if not fixes:
        fk.KENPOM_NAME_FIXES = {}
    try:
        tid = fk.resolve_team_id(name, explicit, teams_map, None)
    finally:
        fk.KENPOM_NAME_FIXES = saved
    return str(tid) if tid else None


def step_of(name, explicit, teams_map):
    """Which cascade step resolves the name, in resolve_team_id's order."""
    if name in explicit:
        return "1 manual row"
    if name in fk.KENPOM_NAME_FIXES and fk.KENPOM_NAME_FIXES[name] in teams_map:
        return "2 hardcoded fix"
    if name in teams_map:
        return "3 exact ESPN name"
    low = name.lower()
    if any(low in e.lower() for e in teams_map):
        return "4 substring"
    kp = low.split()
    if any(e.lower().split()[:len(kp)] == kp for e in teams_map):
        return "5 prefix"
    return "unresolved"


VARIANTS = [
    ("production", "Production: manual rows, fixes, exact, fuzzy", dict(explicit=explicit_now)),
    ("last_season_rows", "Same code with last season's manual rows", dict(explicit=explicit_old)),
    ("no_manual", "No manual rows", dict(explicit={})),
    ("no_manual_no_fixes", "No manual rows and no hardcoded fixes", dict(explicit={}, fixes=False)),
    ("fuzzy_off", "Manual rows, fixes and exact only (fuzzy off)", dict(explicit=explicit_now, fuzzy=False)),
    ("exact_only", "Exact ESPN name only", dict(explicit={}, fixes=False, fuzzy=False)),
]

summary, errors, steps, checks, ambiguity, shuffles = [], [], [], [], [], []
rng = random.Random(20261105)
for uni, (rows, (teams_map, info)) in universes.items():
    conf_of = dict(rows)
    ref = {n: resolve(n, explicit_now, teams_map) for n, _ in rows}

    # Source conference label -> ESPN conference id, by majority over the production resolution
    votes = collections.defaultdict(collections.Counter)
    for n, cf in rows:
        if ref[n] and info.get(ref[n], (None, None))[1]:
            votes[cf][info[ref[n]][1]] += 1
    conf_map = {c: v.most_common(1)[0][0] for c, v in votes.items()}

    ids = [ref[n] for n, _ in rows]
    checks.append(dict(universe=uni, names=len(rows), resolved=sum(i is not None for i in ids),
                       distinct_ids=len({i for i in ids if i}),
                       resolved_to_non_d1=sum(1 for i in ids if i and not info.get(i, (0, None))[1]),
                       conference_disagreements=sum(1 for n, cf in rows if ref[n] and
                                                    conf_map.get(cf) != info.get(ref[n], (0, None))[1]),
                       unresolved_names="; ".join(n for n, _ in rows if ref[n] is None)))

    for st, k in sorted(collections.Counter(step_of(n, explicit_now, teams_map) for n, _ in rows).items()):
        steps.append(dict(universe=uni, step=st, names=k))

    # How ambiguous is the substring step? Distinct ESPN teams whose name contains the source name.
    for n, _ in rows:
        if step_of(n, explicit_now, teams_map) == "4 substring":
            cands = {str(t) for e, t in teams_map.items() if n.lower() in e.lower()}
            ambiguity.append(dict(universe=uni, source_name=n, candidate_teams=len(cands),
                                  resolved_correctly=ref[n] in cands))

    # Order sensitivity: the substring step returns the first hit in table order. Shuffle the table.
    items = list(teams_map.items())
    changed = collections.Counter()
    per_shuffle = []
    for _ in range(N_SHUFFLES):
        rng.shuffle(items)
        tm = dict(items)
        diff = [n for n, _ in rows if resolve(n, explicit_now, tm) != ref[n]]
        per_shuffle.append(len(diff))
        changed.update(diff)
    per_shuffle.sort()
    shuffles.append(dict(universe=uni, shuffles=N_SHUFFLES, mean_names_changed=sum(per_shuffle) / N_SHUFFLES,
                         p05=per_shuffle[int(0.05 * N_SHUFFLES)], p95=per_shuffle[int(0.95 * N_SHUFFLES) - 1],
                         max_changed=per_shuffle[-1], names_ever_changed=len(changed),
                         most_fragile="; ".join(f"{n} ({k / N_SHUFFLES:.0%})" for n, k in changed.most_common(6))))

    for key, label, kw in VARIANTS:
        got = {n: resolve(n, teams_map=teams_map, **kw) for n, _ in rows}
        by_id = collections.defaultdict(list)
        for n, t in got.items():
            if t:
                by_id[t].append(n)
        colliding = {n for ns in by_id.values() if len(ns) > 1 for n in ns}
        c = collections.Counter()
        for n, t in got.items():
            outcome = "unresolved" if t is None else "correct" if t == ref[n] else "wrong"
            c[outcome] += 1
            if outcome != "wrong":
                continue
            name_t, conf_t = info.get(t, ("(not in ESPN teams)", None))
            guard = ("collision guard" if n in colliding else "D1 check" if not conf_t else
                     "conference check" if conf_map.get(conf_of[n]) != conf_t else "nothing")
            c[guard] += 1
            errors.append(dict(universe=uni, variant=key, source_name=n, resolved_to=name_t,
                               correct_team=info.get(ref[n], ("?",))[0], first_guard_to_catch=guard))
        summary.append(dict(universe=uni, variant=key, variant_label=label, names=len(rows),
                            correct=c["correct"], wrong=c["wrong"], unresolved=c["unresolved"],
                            names_in_collisions=len(colliding), wrong_caught_by_collision=c["collision guard"],
                            wrong_caught_by_d1=c["D1 check"], wrong_caught_by_conference=c["conference check"],
                            wrong_silent=c["nothing"]))

# What last season's manual rows did, name by name
last_names = {k: v[0] for k, v in ESPN_LAST[1].items()}
now_names = {k: v[0] for k, v in ESPN_NOW[1].items()}
rows_changed = [dict(source_name=n,
                     last_season_row_points_to=last_names.get(explicit_old[n], "?") if n in explicit_old else "(no row)",
                     row_now_points_to=now_names.get(explicit_now[n], "?") if n in explicit_now else "(no row)")
                for n in sorted(set(explicit_old) | set(explicit_now)) if explicit_old.get(n) != explicit_now.get(n)]

# What reached the 2025-26 ratings table for the affected teams (row counts and names only)
n_dates = arch.execute("SELECT COUNT(DISTINCT rating_date) FROM kenpom_ratings").fetchone()[0]
stored = []
for tid in ["145", "147", "2193", "2856", "16", "62", "344", "149", "151", "350", "2517", "2269"]:
    for nm, k in (arch.execute("SELECT team_name, COUNT(*) FROM kenpom_ratings WHERE team_id = ? GROUP BY 1",
                               (tid,)).fetchall() or [(None, 0)]):
        stored.append(dict(espn_team=last_names.get(tid), kenpom_dates=n_dates, rows_stored=k,
                           rows_hold_ratings_of=nm or "(none)"))

# The mapping table (seed file in git), by source and method
seed = list(csv.DictReader(open(os.path.join(PIPE, "data", "seed", "team_name_mapping.csv"))))
src = {"kenpom_manual": "Ratings sites (KenPom, Barttorvik)", "EXACT": "Market feed", "FUZZY": "Market feed",
       "MANUAL": "Market feed"}
old = collections.Counter(r[0] for r in arch.execute("SELECT match_method FROM team_name_mapping"))
now = collections.Counter(r["match_method"] for r in seed)
composition = [dict(source=src[m], method=m, rows_2026_27=now[m], rows_2025_26=old[m]) for m in
               ["EXACT", "FUZZY", "MANUAL", "kenpom_manual"]]
meta = [dict(seed_rows=len(seed), distinct_espn_ids=len({r["db_team_id"] for r in seed}),
             espn_teams_2026_27=len(ESPN_NOW[1]), espn_d1_2026_27=sum(1 for v in ESPN_NOW[1].values() if v[1]),
             fix_dict_entries=len(fk.KENPOM_NAME_FIXES))]


def write(name, rows):
    with open(os.path.join(OUT, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


for fname, data in [("ablation_summary.csv", summary), ("ablation_errors.csv", errors),
                    ("cascade_steps.csv", steps), ("reference_checks.csv", checks),
                    ("substring_ambiguity.csv", ambiguity), ("order_sensitivity.csv", shuffles),
                    ("manual_rows_changed.csv", rows_changed), ("ratings_rows_2025_26.csv", stored),
                    ("mapping_composition.csv", composition), ("mapping_meta.csv", meta)]:
    write(fname, data)
print(f"resolve_ablation: {len(summary)} variant rows, {len(errors)} wrong resolutions -> {OUT}")
