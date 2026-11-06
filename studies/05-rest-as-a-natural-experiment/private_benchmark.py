"""Aggregates from the private pipeline's conference-tournament rest test (KenPom snapshots, 2022-23 to 2025-26).

Needs the private pipeline and a KenPom subscription, so it is not part of analysis.R. It reuses the pipeline's
scripts/backtest/conf_tournament_fatigue.py and writes aggregates only (no KenPom or market rows) to
results/private_benchmark.csv, which analysis.R reads.

    NCAAB_PRIVATE_ROOT=/path/to/ncaab_2027 /path/to/ncaab_2027/.venv/bin/python3 \
        studies/05-rest-as-a-natural-experiment/private_benchmark.py
"""
import math
import os
import sqlite3
import sys

import numpy as np
import pandas as pd

ROOT = os.environ["NCAAB_PRIVATE_ROOT"]
sys.path.insert(0, os.path.join(ROOT, "scripts", "backtest"))
sys.argv = sys.argv[:1]
import conf_tournament_fatigue as ct  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "private_benchmark.csv")


def build():
    g = pd.read_csv(ct.GAMES, dtype={"game_id": str, "home_team_id": str, "away_team_id": str, "tournament_id": str})
    played = g[(g.completed == 1) & (g.home_score > 0) & (g.away_score > 0)].copy()
    counts = ct.recent_counts(played)
    games = played[played.tournament_id.notna() & (played.conference_game == 1) & (played.season_type == 2)].copy()
    resolve = ct.resolver()
    frames = []
    for season, sub in games.groupby("season"):
        kp, _, _ = ct.kenpom(season, resolve)
        for side in ("home", "away"):
            sub = sub.merge(kp[["game_date", "team_id", "adj_em", "adj_tempo"]].rename(columns={
                "team_id": f"{side}_team_id", "adj_em": f"{side}_em", "adj_tempo": f"{side}_t"}),
                on=["game_date", f"{side}_team_id"], how="left")
        frames.append(sub)
    d = pd.concat(frames).dropna(subset=["home_em", "away_em"]).copy()
    for side in ("home", "away"):
        c = [counts[(gid, tid)] for gid, tid in zip(d.game_id, d[f"{side}_team_id"])]
        d[f"{side}_4d"], d[f"{side}_5d"], d[f"{side}_b2b"] = zip(*c)
    tempo = (d.home_t + d.away_t) / 2
    d["pred"] = (d.home_em - d.away_em) * tempo / 100 + np.where(d.neutral_site == 1, 0.0, ct.HCA)
    d["margin"] = d.home_score - d.away_score
    d["resid"] = d.margin - d.pred
    d["home_win"] = (d.margin > 0).astype(int)
    d["b2b_diff"] = d.away_b2b - d.home_b2b
    d["fat_diff"] = (d.away_4d >= 2).astype(int) - (d.home_4d >= 2).astype(int)
    return d


def market_gap(d):
    db = os.path.join(ROOT, "data", "archive", "ncaab_analytics_2026_final.db")
    o = pd.read_sql("SELECT game_id, consensus_spread, snapshot_time FROM consensus_odds "
                    "WHERE consensus_spread IS NOT NULL", sqlite3.connect(db), dtype={"game_id": str})
    o = o.sort_values("snapshot_time").groupby("game_id").tail(1)
    m = d[d.season == 2026].merge(o[["game_id", "consensus_spread"]], on="game_id")
    one = m[m.b2b_diff != 0]
    flip = np.where(one.b2b_diff > 0, -1, 1)
    gap = flip * (-one.consensus_spread - one.pred)   # market margin minus model margin, tired team's side
    return len(one), float(np.mean(gap)), float(np.std(gap, ddof=1) / math.sqrt(len(gap)))


def main():
    d = build()
    rows = []
    for definition, col in (("played_yesterday", "b2b_diff"), ("two_plus_in_4_days", "fat_diff")):
        for s in sorted(d.season.unique()) + ["all"]:
            sub = d if s == "all" else d[d.season == s]
            b, se = ct.ols(sub.resid.values, sub[col])
            one = sub[sub[col] != 0]
            r = np.where(one[col] > 0, -one.resid, one.resid)
            rows.append(dict(source="private_kenpom", definition=definition, season=s, n_games=len(sub),
                             n_mismatch=len(one), cost_points=b[1], cost_se=se[1],
                             tired_side_mean=float(np.mean(r)),
                             tired_side_se=float(np.std(r, ddof=1) / math.sqrt(len(one)))))
    out = pd.DataFrame(rows)

    loso = []
    for s in sorted(d.season.unique()):
        tr, te = d[d.season != s], d[d.season == s]
        k = ct.ols(tr.resid.values, tr.b2b_diff)[0][1]
        p0, p1 = ct.phi(te.pred / ct.SIGMA), ct.phi((te.pred + k * te.b2b_diff) / ct.SIGMA)
        y = te.home_win.values
        loso.append(dict(source="private_kenpom", definition="loso_brier", season=s, n_games=len(te),
                         n_mismatch=int((te.b2b_diff != 0).sum()), cost_points=k,
                         brier_base=float(np.mean((p0 - y) ** 2)), brier_rest=float(np.mean((p1 - y) ** 2))))
    out = pd.concat([out, pd.DataFrame(loso)])
    n, gap, se = market_gap(d)
    out = pd.concat([out, pd.DataFrame([dict(source="private_market", definition="market_minus_model_tired_side",
                                             season=2026, n_mismatch=n, cost_points=gap, cost_se=se)])])
    out.to_csv(OUT, index=False, float_format="%.4f")
    print(out.to_string(index=False))


if __name__ == "__main__":
    main()
