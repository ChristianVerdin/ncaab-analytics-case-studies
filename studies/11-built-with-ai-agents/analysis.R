# Study 11: building with parallel AI agents, and the gates that kept them honest.
#   Rscript studies/11-built-with-ai-agents/analysis.R      (from the repo root)
# Private input: Claude Code session transcripts (JSONL) and git history, parsed by parse_sessions.py into counts
# and timestamps only. Without the transcripts, the committed results/*.csv are reused.
source("R/theme.R")
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
})

study <- "studies/11-built-with-ai-agents"
res <- function(f) file.path(study, "results", f)
fig <- function(f) file.path(study, "figures", f)
dir.create(file.path(study, "results"), showWarnings = FALSE)
py <- Sys.getenv("NCAAB_PYTHON", path.expand("~/projects/ncaab_2027/.venv/bin/python3"))
projects <- Sys.getenv("CLAUDE_PROJECTS", path.expand("~/.claude/projects"))
if (file.exists(py) && dir.exists(file.path(projects, "-Users-cv-projects-ARCHIVE-OFFSEASON-ncaab"))) {
  cat(system2(py, c(file.path(study, "parse_sessions.py"), file.path(study, "results")), stdout = TRUE), sep = "\n")
} else {
  message("Transcripts not found: reusing committed results.")
}

roster <- read_csv(res("agent_roster.csv"), show_col_types = FALSE)
tl <- read_csv(res("timeline_events.csv"), show_col_types = FALSE)
summ <- read_csv(res("session_summary.csv"), show_col_types = FALSE)
rev <- read_csv(res("security_reviews.csv"), show_col_types = FALSE)
com <- read_csv(res("commits.csv"), show_col_types = FALSE, col_types = cols(commit = col_character()))
own <- read_csv(res("ownership_check.csv"), show_col_types = FALSE)

# ---- Bugs and where they were caught (curated from the transcripts and commit messages; no betting items) ----
bugs <- tribble(
  ~session, ~caught_by, ~bug,
  "1. Season rebuild", "Worker agent", "Market consensus skipped on any run after 6 PM: a UTC date compared with local time",
  "1. Season rebuild", "Worker agent", "The fetch step printed the first and last 4 characters of the API key",
  "1. Season rebuild", "Worker agent", "A 200-credit daily budget could not fit the 1,500-credit monthly plan",
  "1. Season rebuild", "Worker agent", "Bracket import's ESPN game-id lookup always errored (0 of 32 matched in 2025-26)",
  "1. Season rebuild", "Worker agent", "Bracket update never moved play-in winners into the First Round",
  "1. Season rebuild", "Worker agent", "All four 2026 First Four rows named the wrong winner",
  "1. Season rebuild", "Worker agent", "Final Four pairing hardcoded; wrong for 2026",
  "1. Season rebuild", "Worker agent", "Tournament report counted 8 NIT games as NCAA games",
  "1. Season rebuild", "Worker agent", "Tournament report read the predicted winner's probability as the home team's",
  "1. Season rebuild", "Worker agent", "Conference-history script crashed on hoopR 2.x and overwrote rows on re-import",
  "1. Season rebuild", "Worker agent", "Hardcoded league defense average (109.3 vs 104.8) pulled projections about 4% low",
  "1. Season rebuild", "Worker agent", "Pre-2026 seed history had errors (a 16-seed win missing); lead rebuilt it from ESPN",
  "1. Season rebuild", "Worker agent", "Backtest hardcoded last season, so the documented refit could not run",
  "1. Season rebuild", "Worker agent", "Three different game counts quoted for the same backtest",
  "1. Season rebuild", "Automated security review", "API key could reach logs through error messages (fixed in under a minute)",
  "1. Season rebuild", "Lead agent", "Matched-vs-stored count gap: 4 wrong team-id mappings, 2 teams missing (study 09)",
  "1. Season rebuild", "Lead agent", "Teams import failed on an integer-vs-text conference id",
  "1. Season rebuild", "Lead agent", "Old KenPom API path returned 404; client moved to the new scheme and fails loudly",
  "1. Season rebuild", "Lead agent", "Old calibration table skipped home probabilities below 50%",
  "1. Season rebuild", "Lead agent", "Environment script pointed at the wrong folder under zsh",
  "1. Season rebuild", "Lead agent", "Vault step logged a data sync that never happened",
  "1. Season rebuild", "Lead agent", "Manual security review: SQL date filter used a table alias that did not exist",
  "1. Season rebuild", "Lead agent", "Manual security review: health check passed keys on the command line",
  "2. Portfolio build", "Lead agent", "Conference-tournament fatigue adjustment had its sign reversed",
  "2. Portfolio build", "Lead agent", "Two March reports read ids as numbers and matched nothing (study 09)",
  "2. Portfolio build", "Lead agent", "Neutral-site rule missed 32 of 300 conference-tournament games (study 09)"
)
write_csv(bugs, res("bugs_caught.csv"))

# ---- Gates: what each check is and how often it fired --------------------------------------------------------
s1 <- summ %>% filter(grepl("^1", session))
s2 <- summ %>% filter(grepl("^2", session))
r_done <- rev %>% filter(kind == "review", !grepl("did not complete", outcome))
gates <- tribble(
  ~gate, ~how_it_works, ~evidence,
  "Written brief per worker", "Goal, files it may touch, forbidden actions, test plan, report format",
  sprintf("%d briefs of %s characters; session 2 adds one shared brief of 8,360", nrow(roster),
          paste(range(roster$brief_chars, na.rm = TRUE), collapse = "-")),
  "File ownership", "Each worker gets an explicit file list; the lead edits everything else",
  sprintf("%d of %d Edit/Write calls by workers landed outside their list", sum(own$files_outside_brief),
          sum(own$edit_tool_calls)),
  "Workers never commit", "The lead reviews each report, checks claims against the database, then commits by path",
  sprintf("%d commits by workers; %d by the lead", sum(roster$git_commits_by_agent), nrow(com)),
  "Read-only and sandbox rules", "Live database and archive are read-only; tests run on a copy in a scratch folder",
  "March worker replayed 2026 (67 games) and a synthetic 76-team bracket on a database copy",
  "Paid-API budget", "Hard cap on live calls per worker", "Feed worker used 1 of its 2 allowed live calls (3 credits)",
  "Cheap health check", "smoke_test.sh: config, database, mappings, seed files, tests; costs no API credits",
  sprintf("%d runs in session 1", s1$smoke_test_runs),
  "Automated security review", "An LLM reviewer reads each pushed diff; a second pass tries to refute each finding",
  sprintf("%d reviews, %d with findings (2 flagged, 1 refuted, 1 fixed); %d failed to sign in", nrow(rev %>% filter(kind == "review")),
          sum(r_done$findings > 0), sum(grepl("did not complete", rev$outcome))),
  "Manual fallback review", "When the automated review could not run, the lead scanned history, logs and backups",
  "No secrets found; 2 hardening fixes and 1 latent SQL bug",
  "Human scope decisions", "cv answers questions and approves the plan before any code changes",
  "Plan approved after 23 min; 4 questions answered; alerts and one integration removed; scope set to research and tracking"
)
write_csv(gates, res("gates.csv"))
print(gates, width = 200)

# ---- Figure 1: timeline, agents as rows ---------------------------------------------------------------------
S1 <- "Session 1:\nseason rebuild\n(3 workers)"
S2 <- "Session 2:\nfollow-ups, then\nthis portfolio\n(7 workers)"
explore_lab <- c("Audit season-hardcoded values" = "Explore: season literals",
                 "Map pipeline, data flow, deps" = "Explore: pipeline map",
                 "Early-season model readiness" = "Explore: early-season model")
tl2 <- tl %>%
  mutate(start = as.POSIXct(start, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
         end = as.POSIXct(end, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
         row = recode(row, !!!explore_lab),
         session = recode(session, "1. Season rebuild" = S1, "2. Portfolio build" = S2))
row_order <- c("cv (human)", "Lead agent", unname(explore_lab), "odds-agent", "march-agent", "docs-agent",
               "forecast", "roster", "hca", "march", "style", "eng", "ask",
               "Security review (per push)", "Git commit (lead only)")
tl2 <- tl2 %>% mutate(row = factor(row, levels = rev(row_order)))
spans <- tl2 %>% filter(kind == "working") %>% mutate(end = pmax(end, start + 60))
events <- tl2 %>% filter(kind != "working")
# cv's decisions arrive as answers to the lead's questions and plan approval, not as typed messages
decisions <- tribble(
  ~session, ~row, ~t, ~label, ~vj, ~hj,
  S1, "cv (human)", "2026-11-05T15:36:57", "fresh repo", -0.9, 0.5,
  S1, "cv (human)", "2026-11-05T16:03:47", "plan approved", -0.9, 0.5,
  S1, "cv (human)", "2026-11-05T18:41:22", "no alerts", -0.9, 1,
  S1, "cv (human)", "2026-11-05T19:02:09", "research scope", -0.9, 0
) %>% mutate(t = as.POSIXct(t, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"), row = factor(row, levels = levels(tl2$row)))
write_csv(decisions %>% select(-vj, -hj) %>% mutate(session = gsub("\n", " ", session), label = gsub("\n", " ", label),
                                                   time_ct = format(t, "%Y-%m-%dT%H:%M:%S")) %>% select(-t),
          res("human_decisions.csv"))
ann <- tribble(
  ~session, ~row, ~t, ~label, ~vj, ~hj,
  S1, "Security review (per push)", "2026-11-05T16:05:16", "2 flagged, 1 fixed", -0.9, 0.5,
  S1, "Security review (per push)", "2026-11-05T18:59:01", "sign-in failed", -0.9, 0.5
) %>% mutate(t = as.POSIXct(t, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"), row = factor(row, levels = levels(tl2$row))) %>%
  bind_rows(decisions)
p1 <- ggplot() +
  geom_segment(data = spans, aes(x = start, xend = end, y = row, yend = row), colour = cs_pal[["blue"]],
               linewidth = 3.2, lineend = "butt") +
  geom_point(data = events %>% filter(kind == "message"), aes(start, row), colour = cs_pal[["orange"]], size = 2.2) +
  geom_point(data = events %>% filter(kind %in% c("commit", "review", "verification pass")), aes(start, row),
             colour = cs_pal[["orange"]], shape = "|", size = 4) +
  geom_point(data = decisions, aes(t, row), colour = cs_ink[["primary"]], shape = 18, size = 3.2) +
  geom_text(data = ann, aes(t, row, label = label, vjust = vj, hjust = hj), size = 2.6, colour = cs_ink[["secondary"]],
            lineheight = 0.85) +
  facet_grid(session ~ ., scales = "free_y", space = "free_y") +
  scale_x_datetime(date_breaks = "30 min", date_labels = "%H:%M", expand = expansion(mult = 0.01)) +
  labs(title = "One lead, short-lived parallel workers, and every commit made by the lead",
       subtitle = paste("Blue: an agent working (turns under 6 minutes apart). Orange: cv's messages (dots), commits and security reviews (ticks).",
                        "\nBlack diamonds: cv's decisions on the lead's questions and plan."),
       x = "2026-11-05, Central time", y = NULL,
       caption = sprintf(paste("Session 1: %.1f h, %d lead tool calls, %d worker tool calls, %d commits. Session 2 is a snapshot",
                               "while this study was being written.\nSource: Claude Code session transcripts and git history, parsed by parse_sessions.py."),
                         s1$hours, s1$lead_tool_calls, s1$subagent_tool_calls, sum(com$session == s1$session))) +
  theme_cs() +
  theme(panel.grid.major.y = element_blank(), strip.text.y = element_text(angle = 0, hjust = 0),
        strip.placement = "outside")
save_fig(p1, fig("01_agent_timeline.png"), width = 12, height = 7)

# ---- Figure 2: where bugs were caught ------------------------------------------------------------------------
b2 <- bugs %>% count(caught_by, name = "bugs") %>% arrange(bugs) %>%
  mutate(caught_by = factor(caught_by, levels = caught_by))
write_csv(b2, res("fig02_bugs_by_source.csv"))
p2 <- ggplot(b2, aes(bugs, caught_by)) +
  geom_col(fill = cs_pal[["blue"]], width = 0.6) +
  geom_text(aes(label = bugs), hjust = -0.4, size = 3.4, colour = cs_ink[["secondary"]]) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(title = "Workers caught most bugs in their own code; the lead caught the cross-cutting ones",
       subtitle = sprintf("Bugs found and fixed on 2026-11-05, by who caught them (n = %d; two pick-recording fixes not counted)", nrow(bugs)),
       x = "Bugs", y = NULL,
       caption = "Worker counts include problems reported but fixed by the lead. Source: session transcripts and commit messages; list in results/bugs_caught.csv.") +
  theme_cs() +
  theme(panel.grid.major.y = element_blank())
save_fig(p2, fig("02_bugs_by_source.png"), width = 9, height = 3.6)

# Headline numbers for the write-up
w <- roster %>% filter(kind == "teammate")
cat(sprintf("session 1: %.2f h; workers %s; worker minutes %s\n", s1$hours, paste(w$agent[w$session == s1$session], collapse = ", "),
            paste(w$minutes[w$session == s1$session], collapse = ", ")))
cat(sprintf("changes excl. fork commit: %d insertions, %d deletions in %d commits\n",
            sum(com$insertions[com$session == s1$session & com$files < 80]),
            sum(com$deletions[com$session == s1$session & com$files < 80]),
            sum(com$session == s1$session & com$files < 80)))
cat("study 11 done\n")
