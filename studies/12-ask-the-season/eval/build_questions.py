"""Writes eval/questions.jsonl: each question with its gold SQL and the gold answer computed by running that SQL.

The dev/test split is drawn once, stratified by category, with a fixed seed, and then frozen: on later runs the split
of every existing id is read back from questions.jsonl and never redrawn.
    .venv/bin/python3 studies/12-ask-the-season/eval/build_questions.py
"""
import hashlib
import json
import pathlib
import random
import sqlite3
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import server  # noqa: E402  (same read-only guard the MCP server uses)

OUT = HERE / "questions.jsonl"
CANNOT = "CANNOT_ANSWER"

# Fields: id, category, question, gold_sql (None when unanswerable), ordered (row order matters),
# accept_sql (other result shapes that also answer the question), accept_empty (an empty result is also right).
Q = [
    # ---- lookup: one row, one table
    dict(id="L01", category="lookup", question="What was Gonzaga's win-loss record in 2022-23?",
         gold_sql="SELECT wins, losses FROM team_seasons WHERE team_id = '2250' AND season = 2023"),
    dict(id="L02", category="lookup", question="Who won the national championship game in 2023, and what was the score?",
         gold_sql="SELECT CASE WHEN home_score > away_score THEN home_name ELSE away_name END AS winner, "
                  "MAX(home_score, away_score) AS winner_pts, MIN(home_score, away_score) AS loser_pts "
                  "FROM games WHERE season = 2023 AND tourney_round = 'National Championship'"),
    dict(id="L03", category="lookup", question="What was Houston's average tempo in the 2023-24 season?",
         gold_sql="SELECT tempo FROM team_seasons WHERE team_id = '248' AND season = 2024"),
    dict(id="L04", category="lookup", question="Which conference was Texas in during the 2024-25 season?",
         gold_sql="SELECT conference FROM team_seasons WHERE team_id = '251' AND season = 2025"),
    dict(id="L05", category="lookup", question="What was the attendance at the 2024 national championship game?",
         gold_sql="SELECT attendance FROM games WHERE season = 2024 AND tourney_round = 'National Championship'"),
    dict(id="L06", category="lookup", question="What was Michigan's offensive efficiency in 2025-26?",
         gold_sql="SELECT off_eff FROM team_seasons WHERE team_id = '130' AND season = 2026"),
    dict(id="L07", category="lookup", question="What home-court advantage did the rating model estimate for 2020-21?",
         gold_sql="SELECT hca FROM seasons WHERE season = 2021"),
    dict(id="L08", category="lookup", question="What was Saint Mary's effective field goal percentage in 2024-25?",
         gold_sql="SELECT efg_pct FROM team_seasons WHERE team_id = '2608' AND season = 2025"),

    # ---- aggregate: counts, averages, group-bys
    dict(id="A01", category="aggregate", question="How many games went to overtime in the 2025-26 season?",
         gold_sql="SELECT COUNT(*) FROM games WHERE season = 2026 AND ot_periods > 0"),
    dict(id="A02", category="aggregate", question="What was the average combined score of a game in 2024-25?",
         gold_sql="SELECT AVG(home_score + away_score) FROM games WHERE season = 2025"),
    dict(id="A03", category="aggregate", question="How many Division I teams won 30 or more games in 2025-26?",
         gold_sql="SELECT COUNT(*) FROM team_seasons WHERE season = 2026 AND wins >= 30"),
    dict(id="A04", category="aggregate",
         question="In 2020-21, what percentage of non-neutral regular-season games did the home team win?",
         gold_sql="SELECT 100.0 * AVG(margin > 0) FROM games WHERE season = 2021 AND neutral = 0 "
                  "AND game_type = 'regular'"),
    dict(id="A05", category="aggregate", question="Which conference had the highest average team rating in 2025-26?",
         gold_sql="SELECT conference FROM team_seasons WHERE season = 2026 GROUP BY conference "
                  "ORDER BY AVG(rating) DESC LIMIT 1"),
    dict(id="A06", category="aggregate", question="How many games were played in each round of the 2024 NCAA tournament?",
         gold_sql="SELECT tourney_round, COUNT(*) FROM games WHERE season = 2024 AND game_type = 'ncaa_tournament' "
                  "GROUP BY tourney_round"),
    dict(id="A07", category="aggregate",
         question="What was the average attendance at Kentucky's home games (not neutral site) in 2023-24?",
         gold_sql="SELECT AVG(attendance) FROM games WHERE season = 2024 AND home_id = '96' AND neutral = 0"),
    dict(id="A08", category="aggregate", question="How many Division I teams were there in 2019-20?",
         gold_sql="SELECT COUNT(*) FROM team_seasons WHERE season = 2020"),
    dict(id="A09", category="aggregate",
         question="How many NCAA tournament games from 2021 through 2026 were decided by 3 points or fewer?",
         gold_sql="SELECT COUNT(*) FROM games WHERE game_type = 'ncaa_tournament' AND season BETWEEN 2021 AND 2026 "
                  "AND ABS(margin) <= 3"),

    # ---- join: needs two or more tables, or a table joined to itself
    dict(id="J01", category="join", question="Which teams beat Duke in 2024-25?",
         gold_sql="SELECT CASE WHEN home_id = '150' THEN away_name ELSE home_name END FROM games WHERE season = 2025 "
                  "AND ((home_id = '150' AND margin < 0) OR (away_id = '150' AND margin > 0))"),
    dict(id="J02", category="join", question="What conference was each 2025 Final Four team in?",
         gold_sql="SELECT ts.name, ts.conference FROM team_seasons ts WHERE ts.season = 2025 AND ts.team_id IN ("
                  "SELECT home_id FROM games WHERE season = 2025 AND tourney_round = 'Final Four' UNION "
                  "SELECT away_id FROM games WHERE season = 2025 AND tourney_round = 'Final Four')"),
    dict(id="J03", category="join", question="How many games did Big Ten teams win against SEC teams in 2023-24?",
         gold_sql="SELECT COUNT(*) FROM games g JOIN team_seasons h ON h.team_id = g.home_id AND h.season = g.season "
                  "JOIN team_seasons a ON a.team_id = g.away_id AND a.season = g.season WHERE g.season = 2024 AND ("
                  "(h.conference = 'Big Ten' AND a.conference = 'SEC' AND g.margin > 0) OR "
                  "(a.conference = 'Big Ten' AND h.conference = 'SEC' AND g.margin < 0))"),
    dict(id="J04", category="join",
         question="Among teams that lost in the first round of the 2024 NCAA tournament, which had the highest rating?",
         gold_sql="SELECT ts.name FROM games g JOIN team_seasons ts ON ts.season = g.season AND ts.team_id = "
                  "CASE WHEN g.margin > 0 THEN g.away_id ELSE g.home_id END WHERE g.season = 2024 "
                  "AND g.tourney_round = '1st Round' ORDER BY ts.rating DESC LIMIT 1"),
    dict(id="J05", category="join",
         question="What was Iowa State's record in 2025-26 against teams ranked in the top 25 of the rating?",
         gold_sql="SELECT SUM(tg.win), SUM(1 - tg.win) FROM team_games tg JOIN team_seasons o ON o.team_id = tg.opp_id "
                  "AND o.season = tg.season WHERE tg.team_id = '66' AND tg.season = 2026 AND o.rating_rank <= 25"),
    dict(id="J06", category="join", question="For each national champion from 2021 to 2026, what was its rating rank that season?",
         gold_sql="SELECT ts.name, ts.rating_rank FROM games g JOIN team_seasons ts ON ts.season = g.season "
                  "AND ts.team_id = CASE WHEN g.margin > 0 THEN g.home_id ELSE g.away_id END "
                  "WHERE g.tourney_round = 'National Championship'"),
    dict(id="J07", category="join", question="Which team's rating improved the most from 2024-25 to 2025-26?",
         gold_sql="SELECT b.name FROM team_seasons a JOIN team_seasons b ON a.team_id = b.team_id "
                  "WHERE a.season = 2025 AND b.season = 2026 ORDER BY b.rating - a.rating DESC LIMIT 1"),
    dict(id="J08", category="join",
         question="How many points per game did Kansas allow to Big 12 opponents in 2023-24, counting all games?",
         gold_sql="SELECT AVG(tg.opp_pts) FROM team_games tg JOIN team_seasons o ON o.team_id = tg.opp_id "
                  "AND o.season = tg.season WHERE tg.team_id = '2305' AND tg.season = 2024 AND o.conference = 'Big 12'"),

    # ---- comparison: two teams side by side, or a superlative
    dict(id="C01", category="comparison", question="Who had the better defensive efficiency in 2025-26, Houston or Tennessee?",
         gold_sql="SELECT name FROM team_seasons WHERE season = 2026 AND team_id IN ('248', '2633') "
                  "ORDER BY def_eff ASC LIMIT 1",
         accept_sql=["SELECT name, def_eff FROM team_seasons WHERE season = 2026 AND team_id IN ('248', '2633')"]),
    dict(id="C02", category="comparison", question="Which scored more points per game in 2022-23, Alabama or Gonzaga?",
         gold_sql="SELECT name FROM team_seasons WHERE season = 2023 AND team_id IN ('333', '2250') "
                  "ORDER BY ppg DESC LIMIT 1",
         accept_sql=["SELECT name, ppg FROM team_seasons WHERE season = 2023 AND team_id IN ('333', '2250')"]),
    dict(id="C03", category="comparison",
         question="How many times did Duke and North Carolina play from 2019-20 through 2025-26, and how many did Duke win?",
         gold_sql="SELECT COUNT(*), SUM(CASE WHEN (home_id = '150' AND margin > 0) OR (away_id = '150' AND margin < 0) "
                  "THEN 1 ELSE 0 END) FROM games WHERE (home_id = '150' AND away_id = '153') "
                  "OR (home_id = '153' AND away_id = '150')"),
    dict(id="C04", category="comparison", question="Among the top 10 rated teams of 2025-26, which played at the slowest tempo?",
         gold_sql="SELECT name FROM team_seasons WHERE season = 2026 AND rating_rank <= 10 ORDER BY tempo ASC LIMIT 1"),
    dict(id="C05", category="comparison",
         question="Did Kansas or Kentucky have the higher offensive rebounding percentage in 2023-24?",
         gold_sql="SELECT name FROM team_seasons WHERE season = 2024 AND team_id IN ('2305', '96') "
                  "ORDER BY orb_pct DESC LIMIT 1",
         accept_sql=["SELECT name, orb_pct FROM team_seasons WHERE season = 2024 AND team_id IN ('2305', '96')"]),
    dict(id="C06", category="comparison", question="What were the five highest-scoring games, by combined points, in 2025-26?",
         gold_sql="SELECT home_name, away_name FROM games WHERE season = 2026 "
                  "ORDER BY home_score + away_score DESC LIMIT 5", ordered=True),
    dict(id="C07", category="comparison", question="Which Big Ten team had the most conference wins in 2025-26?",
         gold_sql="SELECT name FROM team_seasons WHERE season = 2026 AND conference = 'Big Ten' "
                  "ORDER BY conf_wins DESC LIMIT 1"),
    dict(id="C08", category="comparison",
         question="Compare Michigan and Michigan State's ratings in 2025-26. What was the gap between them?",
         gold_sql="SELECT (SELECT rating FROM team_seasons WHERE season = 2026 AND team_id = '130') - "
                  "(SELECT rating FROM team_seasons WHERE season = 2026 AND team_id = '127')"),

    # ---- time filter: dates, months, before/after
    dict(id="T01", category="time_filter", question="How many games were played on January 17, 2026?",
         gold_sql="SELECT COUNT(*) FROM games WHERE date = '2026-01-17'"),
    dict(id="T02", category="time_filter", question="What was Arizona's record in February 2026?",
         gold_sql="SELECT SUM(CASE WHEN (home_id = '12' AND margin > 0) OR (away_id = '12' AND margin < 0) THEN 1 ELSE 0 END), "
                  "SUM(CASE WHEN (home_id = '12' AND margin < 0) OR (away_id = '12' AND margin > 0) THEN 1 ELSE 0 END) "
                  "FROM games WHERE date BETWEEN '2026-02-01' AND '2026-02-28' AND '12' IN (home_id, away_id)"),
    dict(id="T03", category="time_filter", question="How many games were played in November 2024?",
         gold_sql="SELECT COUNT(*) FROM games WHERE date BETWEEN '2024-11-01' AND '2024-11-30'"),
    dict(id="T04", category="time_filter", question="What was UConn's record before January 1, 2024?",
         gold_sql="SELECT SUM(CASE WHEN (home_id = '41' AND margin > 0) OR (away_id = '41' AND margin < 0) THEN 1 ELSE 0 END), "
                  "SUM(CASE WHEN (home_id = '41' AND margin < 0) OR (away_id = '41' AND margin > 0) THEN 1 ELSE 0 END) "
                  "FROM games WHERE season = 2024 AND date < '2024-01-01' AND '41' IN (home_id, away_id)",
         # Added after the first dev run: the question is ambiguous, so the literal reading (every game in the data
         # before that date) is also accepted. No model answer matched either reading when this was added.
         accept_sql=["SELECT SUM(CASE WHEN (home_id = '41' AND margin > 0) OR (away_id = '41' AND margin < 0) THEN 1 "
                     "ELSE 0 END), SUM(CASE WHEN (home_id = '41' AND margin < 0) OR (away_id = '41' AND margin > 0) "
                     "THEN 1 ELSE 0 END) FROM games WHERE date < '2024-01-01' AND '41' IN (home_id, away_id)"]),
    dict(id="T05", category="time_filter", question="Which teams won at least 10 games in March 2025?",
         gold_sql="SELECT CASE WHEN margin > 0 THEN home_name ELSE away_name END AS winner FROM games "
                  "WHERE date BETWEEN '2025-03-01' AND '2025-03-31' GROUP BY winner HAVING COUNT(*) >= 10"),
    dict(id="T06", category="time_filter", question="How many overtime games were played in December 2022?",
         gold_sql="SELECT COUNT(*) FROM games WHERE date BETWEEN '2022-12-01' AND '2022-12-31' AND ot_periods > 0"),
    dict(id="T07", category="time_filter", question="On what date was the first game of the 2021-22 season played?",
         gold_sql="SELECT MIN(date) FROM games WHERE season = 2022"),
    dict(id="T08", category="time_filter",
         question="What was the average combined score in games played on or after March 1, 2026?",
         gold_sql="SELECT AVG(home_score + away_score) FROM games WHERE date >= '2026-03-01'"),

    # ---- unanswerable from this database: the right answer is to say so
    dict(id="U01", category="unanswerable", question="Who was Duke's leading scorer in 2024-25?", gold_sql=None),
    dict(id="U02", category="unanswerable", question="Where was Purdue ranked in the AP poll in January 2024?", gold_sql=None),
    dict(id="U03", category="unanswerable", question="Who won the 2020 NCAA tournament?", gold_sql=None, accept_empty=True),
    dict(id="U04", category="unanswerable", question="What was Kansas's record in 2018-19?", gold_sql=None, accept_empty=True),
    dict(id="U05", category="unanswerable", question="Which coach won the most games in 2024-25?", gold_sql=None),
    dict(id="U06", category="unanswerable", question="How many minutes did Zach Edey play in the 2024 title game?", gold_sql=None),
    dict(id="U07", category="unanswerable", question="What will Duke's record be in 2026-27?", gold_sql=None, accept_empty=True),
]

TEST_SHARE = 0.4
SEED = 20261105


def assign_splits(qs, existing):
    rng = random.Random(SEED)
    by_cat = {}
    for q in qs:
        by_cat.setdefault(q["category"], []).append(q["id"])
    split = {}
    for cat in sorted(by_cat):
        ids = sorted(by_cat[cat])
        rng.shuffle(ids)
        n_test = round(len(ids) * TEST_SHARE)
        for i, qid in enumerate(ids):
            split[qid] = "test" if i < n_test else "dev"
    for qid, s in existing.items():  # frozen: an id keeps the split it was first given
        split[qid] = s
    return split


def run(con, sql):
    out = server.run_readonly(con, sql)
    if out.get("error"):
        raise SystemExit(f"gold SQL failed: {sql}\n{out['error']}")
    return out["rows"]


def main():
    existing = {}
    if OUT.exists():
        for line in OUT.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                existing[r["id"]] = r["split"]
    split = assign_splits(Q, existing)
    con = server.connect(server.db_path())
    rows = []
    for q in Q:
        r = {"id": q["id"], "split": split[q["id"]], "category": q["category"], "question": q["question"],
             "gold_sql": q["gold_sql"], "ordered": q.get("ordered", False),
             "accept_sql": q.get("accept_sql", []), "accept_empty": q.get("accept_empty", False)}
        if q["gold_sql"] is None:
            r["gold_answer"] = CANNOT
            r["accept_answers"] = []
        else:
            r["gold_answer"] = run(con, q["gold_sql"])
            r["accept_answers"] = [run(con, s) for s in r["accept_sql"]]
        rows.append(r)
    OUT.write_text("".join(json.dumps(r) + "\n" for r in rows))
    frozen = hashlib.sha256("".join(f"{r['id']}|{r['split']}|{r['question']}|{r['gold_sql']}\n"
                                    for r in rows).encode()).hexdigest()
    n = {s: sum(r["split"] == s for r in rows) for s in ("dev", "test")}
    print(f"wrote {OUT.name}: {len(rows)} questions, dev {n['dev']}, test {n['test']}, sha256 {frozen[:16]}")


if __name__ == "__main__":
    main()
