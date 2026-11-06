"""Tests for the ask-the-season MCP server. Stdlib unittest; needs data/ask/season.db (run build_db.R first).
    .venv/bin/python3 -m unittest discover -s studies/12-ask-the-season/tests -v
Each test class works on a temporary copy of the database, and the SQL-safety tests check that the copy's bytes are
unchanged afterwards.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

STUDY = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(STUDY))
import server  # noqa: E402

SOURCE_DB = STUDY.parents[1] / "data" / "ask" / "season.db"
PY = sys.executable


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


@unittest.skipUnless(SOURCE_DB.exists(), "build data/ask/season.db first")
class DbCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.db = pathlib.Path(cls.tmp) / "season.db"
        shutil.copy(SOURCE_DB, cls.db)
        cls.before = sha(cls.db)
        cls.con = server.connect(cls.db)

    @classmethod
    def tearDownClass(cls):
        cls.con.close()
        shutil.rmtree(cls.tmp)


class Protocol(DbCase):
    """Drives the real server over stdio, the way an MCP client does."""

    def setUp(self):
        env = dict(os.environ, ASK_DB=str(self.db))
        self.proc = subprocess.Popen([PY, str(STUDY / "server.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, env=env)

    def tearDown(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)
        self.proc.stdout.close()
        self.proc.stderr.close()

    def send(self, msg, expect_reply=True):
        self.proc.stdin.write((msg if isinstance(msg, str) else json.dumps(msg)) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline()) if expect_reply else None

    def handshake(self):
        r = self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "unittest", "version": "0"}}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect_reply=False)
        return r

    def test_initialize(self):
        r = self.handshake()
        self.assertEqual(r["id"], 1)
        self.assertEqual(r["result"]["protocolVersion"], "2025-06-18")
        self.assertIn("tools", r["result"]["capabilities"])
        self.assertEqual(r["result"]["serverInfo"]["name"], "ask-the-season")

    def test_notification_gets_no_reply_and_ping_works(self):
        self.handshake()
        r = self.send({"jsonrpc": "2.0", "id": "p", "method": "ping"})  # the notification produced no line
        self.assertEqual(r, {"jsonrpc": "2.0", "id": "p", "result": {}})

    def test_tools_list_shape(self):
        self.handshake()
        tools = self.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
        self.assertEqual([t["name"] for t in tools], ["describe_schema", "run_sql", "team_season", "compare_teams"])
        for t in tools:
            self.assertIsInstance(t["description"], str)
            self.assertEqual(t["inputSchema"]["type"], "object")
            self.assertTrue(t["annotations"]["readOnlyHint"])
        self.assertEqual(tools[1]["inputSchema"]["required"], ["sql"])

    def test_tools_call_run_sql(self):
        self.handshake()
        r = self.send({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                       "params": {"name": "run_sql", "arguments": {"sql": "SELECT COUNT(*) AS n FROM seasons"}}})
        res = r["result"]
        self.assertFalse(res["isError"])
        self.assertEqual(res["structuredContent"]["rows"], [[7]])
        self.assertEqual(json.loads(res["content"][0]["text"])["columns"], ["n"])

    def test_tool_error_is_a_result_not_a_protocol_error(self):
        self.handshake()
        r = self.send({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                       "params": {"name": "run_sql", "arguments": {"sql": "DROP TABLE games"}}})
        self.assertTrue(r["result"]["isError"])
        self.assertNotIn("error", r)

    def test_protocol_errors(self):
        self.handshake()
        self.assertEqual(self.send("{not json")["error"]["code"], -32700)
        self.assertEqual(self.send({"jsonrpc": "2.0", "id": 5, "method": "resources/list"})["error"]["code"], -32601)
        r = self.send({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "nope", "arguments": {}}})
        self.assertEqual(r["error"]["code"], -32602)
        self.assertEqual(self.send([{"jsonrpc": "2.0", "id": 7, "method": "ping"}])["error"]["code"], -32600)

    def test_stdout_carries_only_json_rpc(self):
        self.handshake()
        self.send({"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "describe_schema"}})
        self.proc.stdin.close()
        rest = self.proc.stdout.read()
        self.assertEqual(rest, "")
        self.proc.stdin = open(os.devnull, "w")


class SqlSafety(DbCase):
    REFUSED = [
        "DROP TABLE games",
        "DELETE FROM games",
        "UPDATE teams SET name = 'x'",
        "INSERT INTO seasons (season, label) VALUES (1999, 'x')",
        "REPLACE INTO seasons (season, label) VALUES (2026, 'x')",
        "CREATE TABLE t (x)",
        "CREATE TEMP TABLE t AS SELECT 1",
        "ALTER TABLE teams ADD COLUMN x",
        "ATTACH DATABASE '/tmp/evil.db' AS evil",
        "SELECT * FROM games; DROP TABLE games",
        "SELECT 1; SELECT 2",
        "PRAGMA writable_schema = 1",
        "PRAGMA user_version = 7",
        "PRAGMA journal_mode = DELETE",
        "WITH x AS (SELECT 1) DELETE FROM games",
        "WITH x AS (SELECT 1) INSERT INTO seasons (season, label) SELECT 1999, 'x' FROM x",
        "WITH x AS (SELECT 1) UPDATE teams SET name = 'x'",
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n",
        "VACUUM INTO '/tmp/copy.db'",
        "SELECT load_extension('/tmp/evil')",
        "BEGIN IMMEDIATE",
        "/* comment */ DROP TABLE games",
        "-- SELECT\nDELETE FROM games",
    ]

    def test_writes_and_escapes_are_refused(self):
        for sql in self.REFUSED:
            with self.subTest(sql=sql):
                out = server.run_readonly(self.con, sql)
                self.assertIn("error", out, out)
        self.assertEqual(sha(self.db), self.before)
        self.assertFalse(pathlib.Path("/tmp/copy.db").exists() and sha("/tmp/copy.db") == self.before)

    def test_plain_selects_still_work(self):
        for sql in ["SELECT COUNT(*) FROM games", "WITH t AS (SELECT * FROM teams) SELECT COUNT(*) FROM t",
                    "SELECT 1;", "  select name from teams where team_id = '150'  ", "VALUES (1)"]:
            with self.subTest(sql=sql):
                self.assertNotIn("error", server.run_readonly(self.con, sql))

    def test_connection_itself_is_read_only(self):
        con = server.connect(self.db)
        con.set_authorizer(None)  # even with the authorizer removed, mode=ro refuses writes
        with self.assertRaises(Exception):
            con.execute("DELETE FROM games")
        con.close()
        self.assertEqual(sha(self.db), self.before)

    def test_row_cap(self):
        out = server.run_readonly(self.con, "SELECT * FROM games")
        self.assertEqual(out["row_count"], server.ROW_CAP)
        self.assertTrue(out["truncated"])
        small = server.run_readonly(self.con, "SELECT * FROM seasons")
        self.assertEqual(small["row_count"], 7)
        self.assertFalse(small["truncated"])

    def test_timeout(self):
        out = server.run_readonly(self.con, "SELECT COUNT(*) FROM team_games a, team_games b", timeout=0.3)
        self.assertIn("timed out", out["error"])
        self.assertNotIn("error", server.run_readonly(self.con, "SELECT 1"))  # the connection still works

    def test_huge_values_are_capped(self):
        out = server.run_readonly(self.con, "SELECT zeroblob(2000000000)")
        self.assertIn("error", out)


class Names(DbCase):
    def resolve(self, q, season=2026):
        return server.resolve_team(self.con, q, season)

    def test_unique_and_exact(self):
        for q, want in [("Duke", "Duke Blue Devils"), ("duke blue devils", "Duke Blue Devils"),
                        ("UConn", "UConn Huskies"), ("St. John's", "St. John's Red Storm"),
                        ("Saint Johns", "St. John's Red Storm"), ("St Mary's", "Saint Mary's Gaels"),
                        ("Michigan St", "Michigan State Spartans"), ("Texas A&M", "Texas A&M Aggies"),
                        ("150", "Duke Blue Devils"), ("UNC", "North Carolina Tar Heels"),
                        ("Penn", "Pennsylvania Quakers")]:
            with self.subTest(q=q):
                r = self.resolve(q)
                self.assertEqual(r["status"], "resolved", r)
                self.assertEqual(r["name"], want)

    def test_shared_first_word_resolves_to_base_school_and_says_so(self):
        for q, want, other in [("Michigan", "Michigan Wolverines", "Michigan State Spartans"),
                               ("North Carolina", "North Carolina Tar Heels", "North Carolina Central Eagles"),
                               ("Kansas", "Kansas Jayhawks", "Kansas State Wildcats"),
                               ("Miami", "Miami Hurricanes", "Miami (OH) RedHawks")]:
            with self.subTest(q=q):
                r = self.resolve(q)
                self.assertEqual(r["name"], want)
                self.assertIn(other, [c["name"] for c in r["also_matched"]])

    def test_ambiguous_returns_candidates(self):
        r = self.resolve("Loyola")
        self.assertEqual(r["status"], "ambiguous")
        self.assertEqual({c["name"] for c in r["candidates"]},
                         {"Loyola Chicago Ramblers", "Loyola Maryland Greyhounds", "Loyola Marymount Lions"})
        r = self.resolve("Mississippi")
        self.assertEqual(r["status"], "ambiguous")
        self.assertGreaterEqual(len(r["candidates"]), 2)

    def test_not_found_suggests(self):
        r = self.resolve("Gonzagaa")
        self.assertEqual(r["status"], "not_found")
        self.assertIn("Gonzaga Bulldogs", [c["name"] for c in r["candidates"]])
        self.assertEqual(self.resolve("Zzyzx Tech")["status"], "not_found")

    def test_season_pool(self):
        self.assertEqual(self.resolve("Oregon State", 2026)["name"], "Oregon State Beavers")
        self.assertEqual(server.resolve_team(self.con, "Duke", None)["name"], "Duke Blue Devils")


class Tools(DbCase):
    def test_team_season(self):
        out = server.tool_team_season(self.con, {"team": "Michigan", "season": "2025-26"})
        self.assertEqual(out["season"], 2026)
        self.assertEqual(out["team_season"]["rating_rank"], 1)
        self.assertEqual(out["team_season"]["season_label"], "2025-26")

    def test_team_season_ambiguous_raises_with_candidates(self):
        with self.assertRaises(LookupError) as cm:
            server.tool_team_season(self.con, {"team": "Loyola", "season": 2026})
        self.assertEqual(json.loads(str(cm.exception))["status"], "ambiguous")

    def test_bad_season(self):
        with self.assertRaises(ValueError):
            server.tool_team_season(self.con, {"team": "Duke", "season": 2019})

    def test_compare_teams(self):
        out = server.tool_compare_teams(self.con, {"team_a": "Duke", "team_b": "UNC", "season": 2025})
        self.assertEqual(len(out["head_to_head"]), 3)
        self.assertGreater(out["neutral_site_rating_gap"], 0)
        self.assertTrue(0.5 < out["neutral_site_win_prob_a"] < 1)
        self.assertIn("Duke Blue Devils", out["side_by_side"]["rating"])

    def test_describe_schema(self):
        out = server.tool_describe_schema(self.con, {})
        self.assertIn("CREATE TABLE team_seasons", out["schema_sql"])
        self.assertIn("season is the year the season ends", out["notes"])


if __name__ == "__main__":
    unittest.main()
