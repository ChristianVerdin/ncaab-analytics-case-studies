"""Export conference-tournament games 2022-23 to 2025-26 with v2.2's margin and each team's recent schedule,
for study 01's fatigue-penalty audit. Private: written outside the repo and never committed.

It reuses the private pipeline's research code (scripts/backtest/conf_tournament_fatigue.py): ESPN's
conference-tournament flag, the KenPom snapshot dated the game day (no look-ahead), v2.2 at its live
parameters (home court 3.2, sigma 10.8), and step 02's game counts (prior 4 and 5 days, played yesterday).

    <private repo>/.venv/bin/python3 export_conf_tournaments.py --private-repo <private repo> --out <dir>
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

ap = argparse.ArgumentParser()
ap.add_argument("--private-repo", required=True)
ap.add_argument("--out", required=True)
args = ap.parse_args()
root = os.path.abspath(args.private_repo)
sys.argv = sys.argv[:1]   # the research module reads an optional CSV path from argv at import
sys.path.insert(0, os.path.join(root, "scripts", "backtest"))
import conf_tournament_fatigue as ct  # noqa: E402

g = pd.read_csv(os.path.join(root, "data", "archive", "march_games_2023_2026.csv"),
                dtype={"game_id": str, "home_team_id": str, "away_team_id": str, "tournament_id": str})
played = g[(g.completed == 1) & (g.home_score > 0) & (g.away_score > 0)].copy()
counts = ct.recent_counts(played)
games = played[played.tournament_id.notna() & (played.conference_game == 1) & (played.season_type == 2)].copy()

resolve = ct.resolver()
frames = []
for season, sub in games.groupby("season"):
    kp, fm, _ = ct.kenpom(season, resolve)
    for side in ("home", "away"):
        sub = sub.merge(kp[["game_date", "team_id", "adj_em", "adj_tempo"]].rename(columns={
            "team_id": f"{side}_team_id", "adj_em": f"{side}_em", "adj_tempo": f"{side}_t"}),
            on=["game_date", f"{side}_team_id"], how="left")
    sub = sub.merge(fm, on=["game_date", "home_team_id", "away_team_id"], how="left")
    frames.append(sub)
d = pd.concat(frames)
n_all = len(d)
d = d.dropna(subset=["home_em", "away_em"]).copy()
for side in ("home", "away"):
    c = [counts[(gid, tid)] for gid, tid in zip(d.game_id, d[f"{side}_team_id"])]
    d[f"{side}_4d"], d[f"{side}_5d"], d[f"{side}_b2b"] = zip(*c)
    # step 02's rule: 3+ games in the previous 5 days -> -2.0 points, else 2+ in the previous 4 -> -1.0
    d[f"{side}_pen"] = np.where(d[f"{side}_5d"] >= 3, -2.0, np.where(d[f"{side}_4d"] >= 2, -1.0, 0.0))

tempo = (d.home_t + d.away_t) / 2
d["margin_v22"] = (d.home_em - d.away_em) * tempo / 100 + np.where(d.neutral_site == 1, 0.0, ct.HCA)
d["margin"] = d.home_score - d.away_score
d["home_win"] = (d.margin > 0).astype(int)
d["pen_intended"] = d.home_pen - d.away_pen          # home tired -> home margin goes down
d["pen_as_applied"] = d.away_pen - d.home_pen        # what step 02 added to the home margin
d["p_fanmatch"] = d.home_wp / 100

cols = ["season", "game_id", "game_date", "neutral_site", "margin", "home_win", "margin_v22", "home_4d", "home_5d",
        "home_b2b", "away_4d", "away_5d", "away_b2b", "pen_intended", "pen_as_applied", "p_fanmatch"]
os.makedirs(args.out, exist_ok=True)
d[cols].to_csv(os.path.join(args.out, "conf_tournaments_2023_2026.csv"), index=False)
print(f"conf_tournaments_2023_2026.csv: {len(d)} of {n_all} games with KenPom for both teams")
