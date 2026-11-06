#!/usr/bin/env python3
"""Ask the season: a stdio MCP server over seven seasons of public college basketball data. Python stdlib only.

JSON-RPC 2.0, one message per line on stdin and stdout; logs go to stderr. Methods: initialize, ping, tools/list,
tools/call, and the notifications/initialized notification. Tools: describe_schema, run_sql, team_season,
compare_teams. The database is opened read-only, and every statement passes an authorizer that allows only
SELECT, column reads and function calls.

    python3 server.py                  # serves data/ask/season.db; ASK_DB=/path/to/season.db to override
"""
import difflib
import json
import math
import os
import pathlib
import re
import sqlite3
import sys
import time
import unicodedata

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "ask-the-season", "title": "Ask the season (NCAA men's basketball, 2019-20 to 2025-26)",
               "version": "1.0.0"}
HERE = pathlib.Path(__file__).resolve().parent
ROW_CAP = 200
MAX_SQL_CHARS = 20_000
MAX_VALUE_BYTES = 1_000_000


def db_path():
    env = os.environ.get("ASK_DB")
    return pathlib.Path(env) if env else HERE.parents[1] / "data" / "ask" / "season.db"


def sql_timeout():
    return float(os.environ.get("ASK_SQL_TIMEOUT", "5"))


# ---------------------------------------------------------------- read-only SQL

_ALLOWED = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION}
_DENIED_FUNCTIONS = {"load_extension", "readfile", "writefile", "edit", "fts3_tokenizer"}


def _authorizer(action, arg1, arg2, _db, _trigger):
    if action not in _ALLOWED:
        return sqlite3.SQLITE_DENY
    if action == sqlite3.SQLITE_FUNCTION and (arg2 or "").lower() in _DENIED_FUNCTIONS:
        return sqlite3.SQLITE_DENY
    return sqlite3.SQLITE_OK


def connect(path=None):
    path = pathlib.Path(path or db_path()).resolve()
    if not path.exists():
        raise FileNotFoundError(f"{path} not found: build it with Rscript studies/12-ask-the-season/build_db.R")
    con = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, check_same_thread=False)
    con.setlimit(sqlite3.SQLITE_LIMIT_ATTACHED, 0)
    con.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_VALUE_BYTES)
    con.setlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH, MAX_SQL_CHARS)
    con.set_authorizer(_authorizer)
    return con


_COMMENT = re.compile(r"--[^\n]*|/\*.*?\*/", re.S)


def _first_keyword(sql):
    m = re.match(r"\s*([A-Za-z]+)", _COMMENT.sub(" ", sql))
    return m.group(1).upper() if m else ""


def run_readonly(con, sql, row_cap=ROW_CAP, timeout=None):
    """Runs one read-only statement. Returns {columns, rows, row_count, truncated} or {error}."""
    if not isinstance(sql, str) or not sql.strip():
        return {"error": "sql must be a non-empty string"}
    if len(sql) > MAX_SQL_CHARS:
        return {"error": f"sql longer than {MAX_SQL_CHARS} characters"}
    if _first_keyword(sql) not in ("SELECT", "WITH", "VALUES"):
        return {"error": "only a single SELECT (or WITH ... SELECT) statement is allowed"}
    deadline = time.monotonic() + (sql_timeout() if timeout is None else timeout)
    con.set_progress_handler(lambda: 1 if time.monotonic() > deadline else 0, 2_000)
    cur = con.cursor()
    try:
        cur.execute(sql)
        rows = cur.fetchmany(row_cap + 1)
    except sqlite3.ProgrammingError as e:
        msg = str(e)
        if "one statement" in msg:
            msg = "only a single statement is allowed"
        return {"error": msg}
    except sqlite3.DatabaseError as e:
        msg = str(e)
        if msg == "interrupted":
            msg = f"query timed out after {timeout if timeout is not None else sql_timeout():g} s"
        elif "not authorized" in msg:
            msg = "not authorized: this database is read-only and allows SELECT only"
        return {"error": msg}
    finally:
        cur.close()
        con.set_progress_handler(None, 0)
    columns = [d[0] for d in (cur.description or [])]
    truncated = len(rows) > row_cap
    rows = [list(r) for r in rows[:row_cap]]
    return {"columns": columns, "rows": rows, "row_count": len(rows), "truncated": truncated}


# ---------------------------------------------------------------- schema

def schema_text(con):
    ddl = run_readonly(con, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
                            "ORDER BY rowid")
    return ";\n".join(r[0] for r in ddl["rows"]) + ";"


def schema_notes():
    return (HERE / "schema_notes.md").read_text()


# ---------------------------------------------------------------- team names

# Short forms that are not a prefix of ESPN's display name. Keys and values are normalized names.
ALIASES = {
    "unc": "north carolina tar heels", "pitt": "pittsburgh panthers", "penn": "pennsylvania quakers",
    "umass": "massachusetts minutemen", "cal": "california golden bears", "uk": "kentucky wildcats",
    "fau": "florida atlantic owls", "usf": "south florida bulls", "etsu": "east tennessee state buccaneers",
    "zags": "gonzaga bulldogs", "nova": "villanova wildcats", "smc": "st marys gaels",
    "north carolina state": "nc state wolfpack", "nebraska omaha": "omaha mavericks",
}
# A word that, right after the typed name, marks a different school: "Michigan" + "State", "Texas" + "A&M".
QUALIFIERS = {"state", "tech", "am", "at", "southern", "central", "christian", "international", "atlantic", "gulf",
              "city", "valley", "oh", "upstate", "baptist", "poly", "wesleyan", "northern", "eastern", "western"}


def normalize(name):
    s = unicodedata.normalize("NFKD", str(name)).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"['.&]", "", s)
    toks = re.sub(r"[^a-z0-9]+", " ", s).split()
    toks = ["st" if t == "saint" else t for t in toks]
    toks = [("state" if (i > 0 and t == "st") else t) for i, t in enumerate(toks)]
    return " ".join(toks)


def _pool(con, season):
    if season is not None:
        res = run_readonly(con, f"SELECT team_id, name FROM team_seasons WHERE season = {int(season)}", row_cap=10_000)
    else:
        res = run_readonly(con, "SELECT team_id, name FROM teams WHERE conference IS NOT NULL", row_cap=10_000)
    return [(tid, nm, normalize(nm).split()) for tid, nm in res["rows"]]


def resolve_team(con, query, season=None):
    """Returns {status: resolved|ambiguous|not_found, ...}. Never picks silently between equal candidates."""
    pool = _pool(con, season)
    q = str(query or "").strip()
    if not q:
        return {"status": "not_found", "query": q, "candidates": []}
    if q.isdigit():
        hit = [p for p in pool if p[0] == q]
        if hit:
            return {"status": "resolved", "team_id": hit[0][0], "name": hit[0][1], "match": "team_id"}
    nq = normalize(q)
    nq = ALIASES.get(nq, nq)
    qt = nq.split()
    names = lambda ps: [{"team_id": p[0], "name": p[1]} for p in ps]  # noqa: E731

    exact = [p for p in pool if " ".join(p[2]) == nq]
    if len(exact) == 1:
        return {"status": "resolved", "team_id": exact[0][0], "name": exact[0][1], "match": "exact"}

    prefix = [p for p in pool if p[2][:len(qt)] == qt and len(p[2]) > len(qt)]
    if len(prefix) == 1 and prefix[0][2][len(qt)] not in QUALIFIERS:
        return {"status": "resolved", "team_id": prefix[0][0], "name": prefix[0][1], "match": "prefix"}
    if prefix:
        base = [p for p in prefix if p[2][len(qt)] not in QUALIFIERS]
        if base:
            shortest = min(len(p[2]) for p in base)
            best = [p for p in base if len(p[2]) == shortest]
            if len(best) == 1:
                others = [p for p in prefix if p is not best[0]]
                return {"status": "resolved", "team_id": best[0][0], "name": best[0][1],
                        "match": "prefix, shortest school name", "also_matched": names(others)}
        return {"status": "ambiguous", "query": q, "candidates": names(prefix)}

    contains = [p for p in pool if all(t in p[2] for t in qt)]
    if len(contains) == 1:
        return {"status": "resolved", "team_id": contains[0][0], "name": contains[0][1], "match": "all words"}
    if contains:
        return {"status": "ambiguous", "query": q, "candidates": names(contains)}

    def closeness(p):  # best match against any leading part of the name, so a typo in "Gonzaga" still finds it
        return max(difflib.SequenceMatcher(None, nq, " ".join(p[2][:k])).ratio() for k in range(1, len(p[2]) + 1))
    scored = sorted(((closeness(p), p) for p in pool), key=lambda x: -x[0])
    return {"status": "not_found", "query": q, "candidates": names([p for s, p in scored[:5] if s >= 0.75])}


# ---------------------------------------------------------------- tools

def _season(con, season):
    if season is None or season == "":
        return run_readonly(con, "SELECT MAX(season) FROM seasons")["rows"][0][0]
    if isinstance(season, str):
        m = re.fullmatch(r"\s*(\d{4})\s*(?:[-/]\s*(\d{2}|\d{4}))?\s*", season)
        if not m:
            raise ValueError(f"season must look like 2026 or '2025-26', got {season!r}")
        season = int(m.group(1)) + (1 if m.group(2) else 0)
    season = int(season)
    known = [r[0] for r in run_readonly(con, "SELECT season FROM seasons ORDER BY season")["rows"]]
    if season not in known:
        raise ValueError(f"season {season} is not in the data; seasons available: {known[0]}-{known[-1]} "
                         "(named by the year they end: 2026 = 2025-26)")
    return season


def _team_row(con, team_id, season):
    res = run_readonly(con, "SELECT ts.*, s.label AS season_label, (SELECT COUNT(*) FROM team_seasons x WHERE "
                            f"x.season = ts.season) AS teams_rated FROM team_seasons ts JOIN seasons s USING (season) "
                            f"WHERE ts.season = {int(season)} AND ts.team_id = '{int(team_id)}'")
    return dict(zip(res["columns"], res["rows"][0])) if res["rows"] else None


def _need_team(con, query, season):
    r = resolve_team(con, query, season)
    if r["status"] != "resolved":
        raise LookupError(json.dumps(r))
    return r


def tool_describe_schema(con, _args):
    return {"schema_sql": schema_text(con), "notes": schema_notes()}


def tool_run_sql(con, args):
    out = run_readonly(con, args.get("sql"))
    if "error" in out:
        raise RuntimeError(out["error"])
    return out


def tool_team_season(con, args):
    season = _season(con, args.get("season"))
    team = _need_team(con, args.get("team"), season)
    row = _team_row(con, team["team_id"], season)
    return {"match": team, "season": season, "team_season": row}


def tool_compare_teams(con, args):
    season = _season(con, args.get("season"))
    a = _need_team(con, args.get("team_a"), season)
    b = _need_team(con, args.get("team_b"), season)
    if a["team_id"] == b["team_id"]:
        raise ValueError(f"both names resolved to the same team: {a['name']}")
    ra, rb = _team_row(con, a["team_id"], season), _team_row(con, b["team_id"], season)
    sigma = run_readonly(con, f"SELECT sigma FROM seasons WHERE season = {season}")["rows"][0][0]
    gap = round(ra["rating"] - rb["rating"], 2)
    h2h = run_readonly(con, "SELECT date, game_type, home_name, away_name, home_score, away_score, neutral "
                            f"FROM games WHERE season = {season} AND ((home_id = '{int(a['team_id'])}' AND away_id = "
                            f"'{int(b['team_id'])}') OR (home_id = '{int(b['team_id'])}' AND away_id = "
                            f"'{int(a['team_id'])}')) ORDER BY date")
    keys = ["wins", "losses", "rating", "rating_rank", "off_eff", "def_eff", "net_eff", "tempo", "efg_pct", "tov_pct",
            "orb_pct", "ft_rate", "fg3_rate", "opp_efg_pct", "ppg", "opp_ppg", "conference"]
    return {
        "season": season,
        "match": {"team_a": a, "team_b": b},
        "side_by_side": {k: {a["name"]: ra[k], b["name"]: rb[k]} for k in keys},
        "neutral_site_rating_gap": gap,
        "neutral_site_win_prob_a": round(0.5 * (1 + math.erf(gap / (sigma * math.sqrt(2)))), 3),
        "note": "rating = ridge-regression points above an average D1 team, fit on that season's regular-season "
                "games (end-of-season, so it has seen the games it is compared with); win prob = Phi(gap / sigma).",
        "head_to_head": [dict(zip(h2h["columns"], r)) for r in h2h["rows"]],
    }


TEAM_ARG = {"type": "string", "description": "School name as people say it (\"Duke\", \"UConn\", \"St. John's\") "
                                             "or an ESPN team_id"}
SEASON_ARG = {"type": ["integer", "string"],
              "description": "Season by its ending year (2026) or as '2025-26'. Defaults to the latest season."}
TOOLS = [
    {"name": "describe_schema", "title": "Describe the database",
     "description": "Tables, columns and how to use them: season naming, game types, team names, rating meaning. "
                    "Call this before writing SQL.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
     "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False}},
    {"name": "run_sql", "title": "Run a read-only SQL query",
     "description": f"Runs one SQLite SELECT against the season database and returns at most {ROW_CAP} rows. "
                    "Writes, PRAGMA, ATTACH and multiple statements are refused.",
     "inputSchema": {"type": "object", "properties": {"sql": {"type": "string", "description": "One SELECT statement"}},
                     "required": ["sql"], "additionalProperties": False},
     "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False}},
    {"name": "team_season", "title": "One team's season",
     "description": "Record, rating and rank, tempo, efficiency and four factors for one team in one season. "
                    "Ambiguous names return candidates instead of a guess.",
     "inputSchema": {"type": "object", "properties": {"team": TEAM_ARG, "season": SEASON_ARG},
                     "required": ["team"], "additionalProperties": False},
     "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False}},
    {"name": "compare_teams", "title": "Compare two teams",
     "description": "Two teams side by side in one season, their head-to-head games, and the neutral-site rating "
                    "gap. Ambiguous names return candidates instead of a guess.",
     "inputSchema": {"type": "object", "properties": {"team_a": TEAM_ARG, "team_b": TEAM_ARG, "season": SEASON_ARG},
                     "required": ["team_a", "team_b"], "additionalProperties": False},
     "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False}},
]
HANDLERS = {"describe_schema": tool_describe_schema, "run_sql": tool_run_sql, "team_season": tool_team_season,
            "compare_teams": tool_compare_teams}


# ---------------------------------------------------------------- JSON-RPC

class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


def _tool_result(payload, is_error=False):
    text = payload if isinstance(payload, str) else json.dumps(payload, default=str)
    out = {"content": [{"type": "text", "text": text}], "isError": is_error}
    if isinstance(payload, dict) and not is_error:
        out["structuredContent"] = payload
    return out


class Server:
    def __init__(self, path=None):
        self.path = path
        self._con = None

    @property
    def con(self):
        if self._con is None:
            self._con = connect(self.path)
        return self._con

    def handle(self, msg):
        """Returns a response dict, or None for a notification."""
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
            return {"jsonrpc": "2.0", "id": msg.get("id") if isinstance(msg, dict) else None,
                    "error": {"code": -32600, "message": "Invalid Request"}}
        if "id" not in msg:
            return None  # notifications/initialized, notifications/cancelled: nothing to send back
        try:
            result = self.dispatch(msg["method"], msg.get("params") or {})
            return {"jsonrpc": "2.0", "id": msg["id"], "result": result}
        except RpcError as e:
            return {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": e.code, "message": e.message}}
        except Exception as e:  # noqa: BLE001
            print(f"internal error: {e!r}", file=sys.stderr)
            return {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32603, "message": "Internal error"}}

    def dispatch(self, method, params):
        if method == "initialize":
            return {"protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": SERVER_INFO,
                    "instructions": "Public ESPN data for NCAA Division I men's basketball, 2019-20 through 2025-26. "
                                    "Call describe_schema first. Seasons are named by their ending year."}
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": TOOLS}
        if method == "tools/call":
            name, args = params.get("name"), params.get("arguments") or {}
            if name not in HANDLERS:
                raise RpcError(-32602, f"Unknown tool: {name}")
            if not isinstance(args, dict):
                raise RpcError(-32602, "arguments must be an object")
            try:
                return _tool_result(HANDLERS[name](self.con, args))
            except LookupError as e:
                return _tool_result(json.loads(str(e)), is_error=True)
            except (ValueError, RuntimeError, FileNotFoundError, TypeError) as e:
                return _tool_result({"error": str(e)}, is_error=True)
        raise RpcError(-32601, f"Method not found: {method}")


def main():
    srv = Server()
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        else:
            if isinstance(msg, list):
                resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Batches are not supported"}}
            else:
                resp = srv.handle(msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp, default=str) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
