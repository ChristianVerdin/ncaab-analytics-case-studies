"""Export the 2025-26 no-look-ahead backtest, one row per game, for studies 01, 02 and 10.

The output holds forecasts built from licensed data (KenPom, betting lines). It is written outside the repo
and is never committed; the studies publish aggregates and figures only.

It reuses the private pipeline's backtest code (scripts/backtest/backtest_v22.py):
  - each game is rated with the KenPom snapshot dated the game day, published before tip;
  - v2.2's two parameters (home court in points, sigma) are fit on one half of the season by date and
    used to predict the other half (two folds), so every v2.2 probability is out of sample;
  - v2.1 is last season's formula on the same inputs, as shipped (calibration table only for p >= 50)
    and with the table applied symmetrically;
  - FanMatch is KenPom's own pregame probability; the market is the de-vigged consensus moneyline
    (stored from 2026-01-22).

    <private repo>/.venv/bin/python3 export_forecasts.py --private-repo <private repo> --out <dir>
"""
import argparse
import json
import os
import sys

import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--private-repo", required=True)
ap.add_argument("--out", required=True)
args = ap.parse_args()
sys.path.insert(0, os.path.join(os.path.abspath(args.private_repo), "scripts", "backtest"))
import backtest_v22 as bt  # noqa: E402

g, kp = bt.load()
pre, post = bt.lookahead_check(kp, g)

cut = sorted(g.game_date)[len(g) // 2]
g["fold"] = np.where(g.game_date < cut, "A", "B")
g["p_v22"] = np.nan
g["margin_v22"] = np.nan
params = {"cut_date": cut, "lookahead_pre": pre, "lookahead_post": post}
for name, tr, te in (("A", g.game_date >= cut, g.game_date < cut), ("B", g.game_date < cut, g.game_date >= cut)):
    hca, sigma = bt.fit_v22(g[tr])
    params[f"fold_{name}"] = {"hca": hca, "sigma": sigma, "n_train": int(tr.sum()), "n_test": int(te.sum())}
    m = bt.v22_margin(g[te], hca)
    g.loc[te, "margin_v22"] = m
    g.loc[te, "p_v22"] = bt.phi(m / sigma)
hca_all, sigma_all = bt.fit_v22(g)
params["full_season"] = {"hca": hca_all, "sigma": sigma_all, "n": int(len(g))}
g["margin_v22_full"] = bt.v22_margin(g, hca_all)

g["p_v21"] = bt.v21(g, symmetric=False)
g["p_v21_sym"] = bt.v21(g, symmetric=True)
g["p_fanmatch"] = g.home_wp / 100
g["margin_fanmatch"] = g.home_pred - g.visitor_pred
ph = np.where(g.home_moneyline < 0, -g.home_moneyline / (-g.home_moneyline + 100), 100 / (g.home_moneyline + 100))
pa = np.where(g.away_moneyline < 0, -g.away_moneyline / (-g.away_moneyline + 100), 100 / (g.away_moneyline + 100))
g["p_market"] = ph / (ph + pa)
g["margin_market"] = -g.consensus_spread

cols = ["game_id", "game_date", "season_type", "neutral_site", "home_team_id", "away_team_id", "home_win", "margin",
        "fold", "p_v22", "margin_v22", "margin_v22_full", "p_v21", "p_v21_sym", "p_fanmatch", "margin_fanmatch",
        "p_market", "margin_market"]
os.makedirs(args.out, exist_ok=True)
g[cols].to_csv(os.path.join(args.out, "forecasts_2026.csv"), index=False)
with open(os.path.join(args.out, "forecasts_2026_params.json"), "w") as f:
    json.dump(params, f, indent=2)
print(f"forecasts_2026.csv: {len(g)} games; FanMatch {int(g.p_fanmatch.notna().sum())}; "
      f"market {int(g.p_market.notna().sum())}; full-season HCA {hca_all:.2f}, sigma {sigma_all:.1f}")
