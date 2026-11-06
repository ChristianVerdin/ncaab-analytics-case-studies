# Guide: reading, running and extending these studies

This guide is for anyone who wants to check the work, rerun it, or build on it: a reviewer, a hiring manager's technical screener, or a student.

## 1. How each study is laid out
Every study lives in `studies/NN-slug/`:

| File | What it is |
|---|---|
| `README.md` | The write-up. The answer comes first, then the data, method, findings, how I checked them, limitations and next steps. |
| `analysis.R` (or `.py`) | The script that produces every number and figure in the write-up. |
| `figures/*.png` | The charts. Each chart's title states its finding. |
| `results/*.csv` | The numbers behind each chart: aggregates only, so you can check a figure without rerunning anything. |

Read a study in this order: the bold answer at the top, the figures, then "How I checked it" and "Limitations". Those last two sections are where most of the judgment is.

## 2. Running the studies
Requirements: R 4.3 or newer, and Python 3.11+ (standard library, pandas and numpy) for the helper scripts in studies 01, 02, 05, 09, 11 and 12.

```bash
git clone https://github.com/ChristianVerdin/ncaab-analytics-case-studies && cd ncaab-analytics-case-studies
Rscript install.R                 # R packages
Rscript scripts/warm_cache.R      # downloads ~25 seasons of public ESPN data into data/ (about a minute)
Rscript tests/test_ratings.R      # prints "ok"
Rscript studies/04-home-court-advantage/analysis.R
```

Everything runs from the repo root. Downloads are cached in `data/cache/`, which isn't tracked by git, so later runs work offline.

### Which studies need data you may not have
Most studies use only public data: ESPN box scores and schedules through the [hoopR](https://hoopr.sportsdataverse.org) package. A few compare against KenPom ratings and forecasts, which are licensed. Those studies publish only aggregate results and figures, never the underlying ratings. Each study's "Reproduce" section says which parts need a KenPom subscription. Where possible, a public-data replication sits next to the licensed analysis (study 05 is one example).

## 3. Shared building blocks
| File | Provides |
|---|---|
| `R/data.R` | `cbb_games()`, `cbb_team_box()`, `cbb_player_box()`: cached, typed, one row per game, team-game or player-game. `d1_only()` keeps games between D1 teams (a team with an ESPN conference id that season). |
| `R/ratings.R` | `fit_ratings(games, before = date)`: a ridge least-squares rating model (margin = home rating - away rating + home-court advantage). `before =` makes look-ahead impossible. `predict_margin()` gives the expected margin for any pairing. |
| `R/theme.R` | One chart theme and a color palette that was checked for color-vision deficiency. |
| `scripts/check_public.sh` | Run before every push. It fails on tracked data files, licensed-data columns, secrets or betting language. |

Conventions:
- Seasons are named by their ending year in code (`2026` = 2025-26) and written out in prose.
- Ratings are in points per game against an average D1 team on a neutral floor.
- Every estimate carries an uncertainty: a bootstrap interval or a standard error.

## 4. Statistical ground rules used throughout
- **No look-ahead.** Anything used to predict a game is computed only from games before it.
- **Holdouts over in-sample fit.** That means leave-one-season-out, or fitting on earlier seasons and testing on later ones.
- **Proper scoring rules for probabilities.** Brier score and log loss, with calibration shown directly. Straight-up accuracy is reported but never headlined: it rewards confident wrong answers and ignores calibration.
- **Null results get reported.** Several studies find that an appealing idea doesn't hold up (study 05's old fatigue penalty, study 08's close-game "skill"). Those findings are as useful as the positive ones.
- **The betting market appears only as a benchmark forecaster.** Its implied probabilities are the toughest public forecast to match. These studies contain no picks or betting advice.

## 5. Extending a study
1. Copy `studies/_TEMPLATE.md` into a new `studies/NN-slug/README.md`.
2. Write `analysis.R` so it creates everything under `figures/` and `results/` from the cache.
3. Run `scripts/check_public.sh` before committing.

Good next questions are listed in each study's "What I'd do next" section.
