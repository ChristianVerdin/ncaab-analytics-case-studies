# College basketball, studied carefully: 13 analytics case studies

Each study asks one question about men's college basketball, answers it up front with a number and its uncertainty, and shows the checks behind it. Most run on public ESPN data, so anyone can rerun them. The aim is the habits that matter in any data job:
- forecasts scored with proper rules
- no look-ahead
- held-out tests
- honest null results
- pipelines that fail loudly instead of quietly

There are no picks and no betting content here. Where the betting market appears, it is treated as what it is: the toughest public forecast to measure against.

**By Christian Verdin.** [GitHub](https://github.com/ChristianVerdin) · [LinkedIn](https://www.linkedin.com/in/christian-verdin/)

## Where to start
| If you're hiring for | Read these first | What they show |
|---|---|---|
| **Data science** | [02](studies/02-judging-forecasts), [05](studies/05-rest-as-a-natural-experiment), [03](studies/03-the-transfer-portal-era) | Calibration and scoring rules, a natural experiment with an independent replication, a holdout-validated model built from 2 million records |
| **Analytics** | [13](studies/13-weekly-state-of-the-season), [04](studies/04-home-court-advantage), [06](studies/06-forty-one-years-of-march) | A recurring report a non-specialist can read, a 25-season trend with a natural experiment, a clear answer to a question everyone argues about |
| **AI engineering** | [12](studies/12-ask-the-season), [11](studies/11-built-with-ai-agents), [09](studies/09-joining-four-data-sources) | An MCP server with an LLM evaluation, multi-agent work with guardrails, entity resolution across four sources |
| **Analytics or data science management** | [01](studies/01-auditing-an-inherited-model), [10](studies/10-running-a-model-in-production), [11](studies/11-built-with-ai-agents) | Auditing an inherited model and ranking its defects by harm, monitoring that is tested for false alarms, running a team of agents with clear gates |

## The studies
| # | Question | Answer | Methods |
|---|---|---|---|
| [01](studies/01-auditing-an-inherited-model) | What was wrong with last season's model? | Seven defects, two of them severe, and none visible in the headline numbers. Away-favorite forecasts claimed 71% and won 61% (95% CI 58% to 63%), while the season-wide average looked fine. | Model audit, calibration by segment, paired bootstrap, patch-vs-replace analysis |
| [02](studies/02-judging-forecasts) | How good is a three-parameter ratings model? | It matched KenPom's own forecasts (Brier 0.1786 vs 0.1781 on 5,751 games; gap not distinguishable from zero). The betting market was better, by 0.0056 (CI 0.0021 to 0.0090). The old model lost on calibration, not on discrimination. | No-look-ahead backtest, reliability diagrams, Murphy decomposition, bootstrap CIs |
| [03](studies/03-the-transfer-portal-era) | In the transfer-portal era, how much of a team carries over? | Returning players' share of D1 minutes fell from 66% to 34%, yet team strength carries over as before (year-to-year r 0.83 vs 0.81). A roster-aware preseason rating beats last season's rating in 12 of 12 holdout seasons. | Linking 2 million player records, feature engineering, clustered bootstrap, rolling-origin holdout |
| [04](studies/04-home-court-advantage) | Is home-court advantage shrinking, and do crowds cause it? | It fell from 4.3 to 3.2 points over 25 seasons. Empty arenas in 2020-21 cut it by 1.3 points, but within the same home team the drop is 0.5 and uncertain. | Ridge ratings, bootstrap, natural experiment, fixed effects, placebo tests, literature comparison |
| [05](studies/05-rest-as-a-natural-experiment) | Does playing yesterday cost a team? | Yes, about 1.5 points (95% CI 0.9 to 2.1, 5,034 conference-tournament games). A production adjustment that pointed the wrong way was replaced with this estimate. | Natural experiment, independent replication on private ratings, leave-one-season-out scoring |
| [06](studies/06-forty-one-years-of-march) | What do 2,644 tournament games say about seeds and upsets? | 8 vs 9 is a coin flip (47%), and upsets are not becoming more common. Ratings beat the seed line only slightly (Brier 0.187 vs 0.194). The new 76-team field gives the added teams a 0.03% title chance. | Jeffreys intervals, exact bracket probabilities by dynamic programming, Monte Carlo, scenario analysis |
| [07](studies/07-team-archetypes) | What kinds of teams are there, and does style matter in March? | There are no natural style clusters, but four archetypes are reproducible (bootstrap ARI 0.83). None wins more March games than its quality predicts (pre-specified test, p = 0.48). | k-means against a null reference, bootstrap stability, PCA, permutation test, power analysis |
| [08](studies/08-luck-and-regression-to-the-mean) | Is winning close games a skill? | No measurable amount. Close-game records correlate 0.01 from one half-season to the next, against 0.52 for point margin. The luckiest tenth of teams falls from +2.0 wins to +0.1. | Split-half reliability, variance decomposition against chance, calibration fix found and disclosed |
| [09](studies/09-joining-four-data-sources) | How often does joining four data sources go wrong? | A third of team names differ across sources. Last season, 6 teams' ratings went to the wrong team without an error. Two guards now stop all six, one of them added the night this study found the gap. | Entity resolution, ablation, threshold sweep, SQL type semantics |
| [10](studies/10-running-a-model-in-production) | What would monitoring have caught? | Four alert rules, fixed in advance, flag last season's calibration defect in week two of a replay. Simulating clean seasons showed one rule would false-alarm in 21% of them. | Monitoring design, simulated false-alarm rates, architecture and failure modes |
| [11](studies/11-built-with-ai-agents) | Can parallel AI agents do real pipeline work without losing control? | A lead and six helpers rebuilt a season pipeline in four hours: 26 commits, 26 bugs fixed. No helper commits, and no file edits outside a helper's brief. | Multi-agent orchestration, guardrails, transcript analysis |
| [12](studies/12-ask-the-season) | Can an LLM answer plain-English questions about a season correctly? | Yes, with the right context. With only the database schema, Claude Haiku 4.5 answered 9 of 19 held-out questions; with column notes, rules and examples tuned on a separate dev set, 18 of 19 (9 gained, 0 lost, McNemar p = 0.004). The whole evaluation cost $0.28. | Zero-dependency MCP server, text-to-SQL, held-out evaluation, McNemar test, cost tracking |
| [13](studies/13-weekly-state-of-the-season) | What does an honest weekly briefing look like? | One script turns a season's box scores into a dated report: top 25 and movers, efficiency, luck and conference strength. It runs every Monday on the live season. | Automated reporting, metric design, defensive engineering |

## How it's built
- **One shared data layer** (`R/data.R`) loads and caches 25 seasons of public ESPN data through [hoopR](https://hoopr.sportsdataverse.org): about 142,000 games, 222,000 team box scores and 2 million player box scores.
- **One public rating model** (`R/ratings.R`): ridge least squares on game margins, with home-court advantage, and with a `before =` argument that makes look-ahead impossible. It is tested on simulated data.
- **One chart theme** with a color palette checked for color-vision deficiency. Every chart has a matching CSV of its numbers.
- **One rule for what can be published** (`scripts/check_public.sh`, run before every push). No data files, no licensed ratings or market columns, no secrets and no betting language.

How to read, rerun and extend the studies: [GUIDE.md](GUIDE.md).

## Data and licensing
- **Code:** MIT.
- **Public data:** game and player data come from ESPN through the sportsdataverse's hoopR package and are downloaded at run time, not stored here.
- **Licensed data:** studies 01, 02, 05, 06 and 10 also use data from a private pipeline: KenPom ratings and forecasts, market lines and historical brackets. They publish only aggregate results and figures, never the underlying data. Where possible, a public-data version of the same analysis is included.
- Team names are ESPN's.
