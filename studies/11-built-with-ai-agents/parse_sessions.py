"""Turn Claude Code session transcripts (JSONL) into counts and a timeline. Private input, public aggregates.

Reads the lead session, its subagent transcripts, the automated security-review sessions and the git history.
Writes only agent names, timestamps, counts and outcomes: no prompts, no messages, no file contents, no secrets.

    python3 parse_sessions.py <out_dir>
Env: CLAUDE_PROJECTS (default ~/.claude/projects), NCAAB_PIPELINE_DIR, PORTFOLIO_DIR.
"""
import collections
import csv
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
PROJ = os.environ.get("CLAUDE_PROJECTS", os.path.expanduser("~/.claude/projects"))
PIPE = os.environ.get("NCAAB_PIPELINE_DIR", os.path.expanduser("~/projects/ncaab_2027"))
PORT = os.environ.get("PORTFOLIO_DIR", os.path.expanduser("~/projects/portfolio/ncaab-analytics-case-studies"))
CT = timezone(timedelta(hours=-6))  # CST; DST ended 2026-11-01

SESSIONS = {
    "1. Season rebuild": os.path.join(PROJ, "-Users-cv-projects-ARCHIVE-OFFSEASON-ncaab",
                                      "b68e9431-7acb-49ed-9e39-de00cfb2b677"),
    "2. Portfolio build": os.path.join(PROJ, "-Users-cv-projects-ncaab-2027", "d5c18cf0-599a-4a14-9fb9-987a42cc51c1"),
}
REVIEW_DIR = os.path.join(PROJ, "-Users-cv-projects-ncaab-2027")
# Agent display names (none currently renamed).
ALIAS = {}
GAP = timedelta(minutes=6)
# git run as a command (start of line or after ; && | or a subshell), not the words inside a script or a search
GIT_CMD = r"(?:^|[;&|(]\s*|\n\s*)git\s+(?:-C\s+\S+\s+)?{}\b"  # assistant turns closer than this belong to one stretch of work


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(CT)


def records(path):
    with open(path) as f:
        for line in f:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def user_text(o):
    c = o.get("message", {}).get("content")
    if isinstance(c, str):
        return c
    return " ".join(x.get("text", "") for x in (c or []) if isinstance(x, dict) and x.get("type") == "text")


def scan(path):
    """Assistant timestamps, tool calls by name, git commits/pushes, human messages, compactions."""
    t_asst, tools, commits, pushes, human, compactions, spawns = [], collections.Counter(), 0, 0, [], 0, []
    edited = []
    smoke = parse_checks = 0
    for o in records(path):
        if o.get("type") == "assistant":
            t_asst.append(ts(o["timestamp"]))
            for c in o["message"].get("content") or []:
                if c.get("type") != "tool_use":
                    continue
                tools[c["name"]] += 1
                if c["name"] in ("Edit", "Write", "NotebookEdit"):
                    edited.append(c["input"].get("file_path") or c["input"].get("notebook_path") or "")
                if c["name"] == "Agent":
                    spawns.append((ts(o["timestamp"]), c["input"].get("name") or c["input"].get("description"),
                                   len(c["input"].get("prompt", ""))))
                if c["name"] == "Bash":
                    cmd = c["input"].get("command", "")
                    commits += len(re.findall(GIT_CMD.format("commit"), cmd))
                    pushes += len(re.findall(GIT_CMD.format("push"), cmd))
                    smoke += "smoke_test.sh" in cmd
                    parse_checks += bool(re.search(r"py_compile|parse\(file|bash -n", cmd))
        elif o.get("type") == "user" and o.get("timestamp"):
            t = user_text(o).strip()
            if t.startswith("This session is being continued"):
                compactions += 1
            elif t and not t.startswith(("<", "Base directory for this skill", "Another Claude session")):
                human.append(ts(o["timestamp"]))
    return dict(edited=edited, t=t_asst, tools=tools, commits=commits, pushes=pushes, human=human, compactions=compactions,
                spawns=spawns, smoke=smoke, parse_checks=parse_checks)


def stretches(times):
    out, start, prev = [], None, None
    for t in sorted(times):
        if start is None:
            start = prev = t
        elif t - prev > GAP:
            out.append((start, prev))
            start = prev = t
        else:
            prev = t
    if start is not None:
        out.append((start, prev))
    return out


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S")


roster, timeline, summary = [], [], []
for sess, base in SESSIONS.items():
    lead = scan(base + ".jsonl")
    for a, b in stretches(lead["t"]):
        timeline.append(dict(session=sess, row="Lead agent", kind="working", start=iso(a), end=iso(b)))
    for h in lead["human"]:
        timeline.append(dict(session=sess, row="cv (human)", kind="message", start=iso(h), end=iso(h)))
    briefs = {name: n for _, name, n in lead["spawns"]}
    agents = []
    for meta_path in sorted(glob.glob(os.path.join(base, "subagents", "*.meta.json"))):
        meta = json.load(open(meta_path))
        s = scan(meta_path.replace(".meta.json", ".jsonl"))
        name = meta.get("name") or meta.get("description")
        label = ALIAS.get(name, name)
        kind = "Explore (read-only)" if meta.get("agentType") == "Explore" else "teammate"
        if not s["t"]:
            continue
        agents.append(label)
        edits = sum(s["tools"][k] for k in ("Edit", "Write", "NotebookEdit"))
        roster.append(dict(session=sess, agent=label, kind=kind,
                           task=meta.get("description") or "",
                           brief_chars=briefs.get(name, briefs.get(meta.get("description"), "")),
                           start_ct=iso(min(s["t"])), end_ct=iso(max(s["t"])),
                           minutes=round((max(s["t"]) - min(s["t"])).total_seconds() / 60),
                           tool_calls=sum(s["tools"].values()), bash_calls=s["tools"]["Bash"], edit_write_calls=edits,
                           web_calls=sum(v for k, v in s["tools"].items() if "firecrawl" in k or k.startswith("Web")),
                           git_commits_by_agent=s["commits"], git_pushes_by_agent=s["pushes"],
                           messages_to_lead=s["tools"]["SendMessage"]))
        for a, b in stretches(s["t"]):
            timeline.append(dict(session=sess, row=label, kind="working", start=iso(a), end=iso(b)))
    summary.append(dict(session=sess, start_ct=iso(min(lead["t"])), end_ct=iso(max(lead["t"])),
                        hours=round((max(lead["t"]) - min(lead["t"])).total_seconds() / 3600, 2),
                        lead_tool_calls=sum(lead["tools"].values()), lead_bash_calls=lead["tools"]["Bash"],
                        agents_spawned=len(lead["spawns"]), human_messages=len(lead["human"]),
                        lead_commit_commands=lead["commits"], lead_push_commands=lead["pushes"],
                        smoke_test_runs=lead["smoke"], context_compactions=lead["compactions"],
                        subagent_tool_calls=sum(r["tool_calls"] for r in roster if r["session"] == sess),
                        subagent_commits=sum(r["git_commits_by_agent"] for r in roster if r["session"] == sess)))

# Automated security reviews: one short session per commit or push, plus verification passes
reviews = []
for p in sorted(glob.glob(os.path.join(REVIEW_DIR, "*.jsonl"))):
    if os.path.basename(p).startswith("d5c18cf0"):
        continue
    first_user, so, t0, failed = None, None, None, False
    for o in records(p):
        if o.get("timestamp") and t0 is None:
            t0 = ts(o["timestamp"])
        if o.get("type") == "user" and first_user is None:
            first_user = user_text(o)
        if o.get("type") == "assistant":
            for c in o["message"].get("content") or []:
                if c.get("type") == "tool_use" and c["name"] == "StructuredOutput":
                    so = c["input"]
                if c.get("type") == "text" and "Failed to authenticate" in c.get("text", ""):
                    failed = True
    if not first_user:
        continue
    if first_user.startswith("You previously flagged"):
        kind, files = "verification pass", 0
        outcome = (f"{len(so.get('survived', []))} kept, {len(so.get('refuted', []))} refuted" if so else "no output")
        n_find = len(so.get("survived", [])) if so else 0
    elif first_user.startswith("Review this change"):
        kind = "review"
        files = len(re.findall(r"^\s+- \S+$", first_user.split("Unified diff")[0], re.M))
        n_find = len(so.get("findings", [])) if so else 0
        outcome = "did not complete (sign-in rejected)" if failed or so is None else (
            f"{n_find} finding(s)" if n_find else "no findings")
    else:
        continue
    reviews.append(dict(start_ct=iso(t0), kind=kind, files_reviewed=files, findings=n_find, outcome=outcome))
    timeline.append(dict(session="1. Season rebuild", row="Security review (per push)", kind=kind,
                         start=iso(t0), end=iso(t0)))

# Commits, from git (counts only)
commits = []
for repo, sess_of in [(PIPE, None), (PORT, "2. Portfolio build")]:
    log = subprocess.run(["git", "-C", repo, "log", "--format=@%h|%ad", "--date=iso-strict", "--numstat"],
                         capture_output=True, text=True).stdout
    for block in log.split("@")[1:]:
        head, *rest = block.strip().split("\n")
        h, d = head.split("|")
        t = datetime.fromisoformat(d).astimezone(CT)
        if t.date().isoformat() != "2026-11-05":
            continue
        ins = dels = nfiles = 0
        for line in rest:
            parts = line.split("\t")
            if len(parts) == 3:
                nfiles += 1
                ins += int(parts[0]) if parts[0].isdigit() else 0
                dels += int(parts[1]) if parts[1].isdigit() else 0
        sess = sess_of or ("1. Season rebuild" if t <= datetime.fromisoformat(summary[0]["end_ct"]).replace(tzinfo=CT)
                           else "2. Portfolio build")
        commits.append(dict(repo=os.path.basename(repo), session=sess, commit=h, time_ct=iso(t), files=nfiles,
                            insertions=ins, deletions=dels))
        timeline.append(dict(session=sess, row="Git commit (lead only)", kind="commit", start=iso(t), end=iso(t)))

# File ownership: every file a worker edited with the Edit/Write tools, against the files its brief allowed.
# (Edits made through shell commands are not counted; the lead's commits by path are the second check.)
MARCH_FILES = {"scripts/fetch_bracket.py", "R/analyses/15_bracket_import.R", "R/analyses/17_bracket_update.R",
               "R/models/tournament_simulator.R", "R/analyses/16_ncaa_tournament_report.R",
               "R/analyses/09_tournament_history.R", "R/analyses/14_fetch_conf_tournament_historical.R",
               "scripts/analyze_player_props.py", "scripts/fetch_player_props.py", "scripts/export_player_stats.py",
               "R/config/seed_history.R"}
FEED_FILES = {"R/models/odds_api.R", "R/config/odds_config.R", "R/analyses/08_fetch_odds.R", "scripts/fetch_odds.py",
              "requirements.txt"}
STUDIES = {"forecast": ("01-", "02-", "10-"), "roster": ("03-",), "hca": ("04-", "08-"), "march": ("05-", "06-"),
           "style": ("07-",), "eng": ("09-", "11-"), "ask": ("12-",)}


def allowed(sess, agent, path):
    rel_pipe = os.path.relpath(path, PIPE)
    rel_port = os.path.relpath(path, PORT)
    if agent == "odds-agent":
        return rel_pipe in FEED_FILES
    if agent == "march-agent":
        return rel_pipe in MARCH_FILES
    if agent == "docs-agent":
        return not rel_pipe.startswith("..") and not re.search(r"\.(R|py|sh|yml|db|csv)$", rel_pipe)
    if agent in STUDIES:
        return rel_port.startswith(tuple("studies/" + p for p in STUDIES[agent]))
    return False


ownership = []
for sess, base in SESSIONS.items():
    for meta_path in sorted(glob.glob(os.path.join(base, "subagents", "*.meta.json"))):
        meta = json.load(open(meta_path))
        name = meta.get("name")
        if not name:
            continue
        label = ALIAS.get(name, name)
        paths = [p for p in scan(meta_path.replace(".meta.json", ".jsonl"))["edited"] if p]
        scratch = [p for p in paths if p.startswith(("/private/tmp", "/tmp"))]
        repo = [p for p in paths if p not in scratch]
        outside = sorted({os.path.relpath(p, PORT if sess.startswith("2") else PIPE) for p in repo
                          if not allowed(sess, label, p)})
        ownership.append(dict(session=sess, agent=label, edit_tool_calls=len(paths),
                              distinct_repo_files=len(set(repo)), scratch_files=len(set(scratch)),
                              files_outside_brief=len(outside), outside_files="; ".join(outside)))


def write(name, rows):
    if not rows:
        return
    with open(os.path.join(OUT, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


write("agent_roster.csv", roster)
write("timeline_events.csv", timeline)
write("session_summary.csv", summary)
write("security_reviews.csv", reviews)
write("commits.csv", commits)
write("ownership_check.csv", ownership)
print(f"parse_sessions: {len(roster)} agents, {len(timeline)} timeline rows, {len(reviews)} reviews, "
      f"{len(commits)} commits -> {OUT}")
