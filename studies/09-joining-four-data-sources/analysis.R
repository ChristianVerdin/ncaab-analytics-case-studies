# Study 09: entity resolution across ESPN, KenPom, Barttorvik and the market feed.
#   Rscript studies/09-joining-four-data-sources/analysis.R      (from the repo root)
# Private part (needs the pipeline at NCAAB_PIPELINE_DIR): replays the production name resolvers and writes
# team names and counts only. Without it, the committed results/*.csv are reused and only the public parts rerun.
source("R/data.R")
source("R/theme.R")
suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(readr)
  library(tidyr)
})

study <- "studies/09-joining-four-data-sources"
res <- function(f) file.path(study, "results", f)
fig <- function(f) file.path(study, "figures", f)
dir.create(file.path(study, "results"), showWarnings = FALSE)
pipe <- Sys.getenv("NCAAB_PIPELINE_DIR", "/Users/cv/projects/ncaab_2027")
py <- Sys.getenv("NCAAB_PYTHON", file.path(pipe, ".venv/bin/python3"))
have_private <- file.exists(file.path(pipe, "data/ncaab_analytics.db")) && file.exists(py)
ro <- function(p) dbConnect(SQLite(), file.path(pipe, p), flags = SQLITE_RO)
wilson <- function(k, n, z = 1.96) {
  p <- k / n
  d <- 1 + z^2 / n
  c <- (p + z^2 / (2 * n)) / d
  h <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  cbind(lo = c - h, hi = c + h)
}

# ---- 1. Ratings-site names: replay the production resolver (Python, private) -------------------------------
if (have_private) {
  out <- system2(py, c(file.path(study, "resolve_ablation.py"), file.path(study, "results")), stdout = TRUE)
  cat(out, sep = "\n")
} else {
  message("Pipeline not found at ", pipe, ": reusing committed results for the private parts.")
}

# ---- 2. Market-feed names: Jaro-Winkler threshold sweep (private names list, R) -----------------------------
# Replays match_team_to_db() without its cache: exact team_name, exact display name, then the best Jaro-Winkler
# match on team_name and on display name if it clears the threshold. Truth = the current, hand-checked mapping.
if (have_private && requireNamespace("stringdist", quietly = TRUE)) {
  seed <- read.csv(file.path(pipe, "data/seed/team_name_mapping.csv"), colClasses = "character") %>%
    filter(match_method != "kenpom_manual")
  sweep_one <- function(db, label) {
    con <- ro(db)
    tm <- dbGetQuery(con, "SELECT team_id, team_name, COALESCE(team_display_name, team_name) AS disp FROM teams")
    dbDisconnect(con)
    nm <- tolower(seed$api_team_name)
    best_of <- function(col) {
      m <- sapply(tolower(col), function(t) stringdist::stringsim(nm, t, method = "jw"))
      list(id = tm$team_id[apply(m, 1, which.max)], sim = apply(m, 1, max))
    }
    b1 <- best_of(tm$team_name)
    b2 <- best_of(tm$disp)
    exact <- tm$team_id[match(seed$api_team_name, tm$team_name)]
    exact <- ifelse(is.na(exact), tm$team_id[match(seed$api_team_name, tm$disp)], exact)
    bind_rows(lapply(seq(0.70, 0.95, by = 0.01), function(thr) {
      got <- ifelse(!is.na(exact), exact,
                    ifelse(b1$sim >= thr, b1$id, ifelse(b2$sim >= thr, b2$id, NA)))
      tibble(universe = label, threshold = round(thr, 2), names = nrow(seed),
             correct = sum(got == seed$db_team_id, na.rm = TRUE),
             wrong = sum(got != seed$db_team_id, na.rm = TRUE), unmatched = sum(is.na(got)),
             wrong_names = paste(seed$api_team_name[!is.na(got) & got != seed$db_team_id], collapse = "; "))
    }))
  }
  sweep <- bind_rows(sweep_one("data/archive/ncaab_analytics_2026_final.db", "ESPN teams 2025-26"),
                     sweep_one("data/ncaab_analytics.db", "ESPN teams 2026-27"))
  write_csv(sweep, res("fuzzy_threshold_sweep.csv"))

  # Orientation: which of the 2026-11-05 feed events matched ESPN only with home/away swapped (names only)
  raw_feed <- file.path(pipe, "outputs/reports/odds_raw_2026-11-05.json")
  ev <- if (file.exists(raw_feed)) jsonlite::fromJSON(raw_feed, simplifyVector = FALSE) else list()
  con <- ro("data/ncaab_analytics.db")
  map <- dbGetQuery(con, "SELECT api_team_name, db_team_id FROM team_name_mapping")
  games <- dbGetQuery(con, "SELECT game_id, game_date, home_team_id, away_team_id, home_team_name, away_team_name,
                                   COALESCE(neutral_site, 0) AS neutral FROM games WHERE season = 2027")
  dbDisconnect(con)
  find <- function(h, a, d) games %>% filter(home_team_id == h, away_team_id == a,
                                             abs(as.numeric(as.Date(game_date) - d)) <= 1)
  flips <- bind_rows(lapply(ev, function(e) {
    h <- map$db_team_id[match(e$home_team, map$api_team_name)]
    a <- map$db_team_id[match(e$away_team, map$api_team_name)]
    d <- as.Date(substr(e$commence_time, 1, 10))
    if (is.na(h) || is.na(a)) return(tibble(orientation = "names unmatched", neutral = NA, espn_game = NA))
    g <- find(h, a, d)
    if (nrow(g)) return(tibble(orientation = "same as ESPN", neutral = g$neutral[1], espn_game = NA))
    g <- find(a, h, d)
    if (nrow(g)) return(tibble(orientation = "reversed", neutral = g$neutral[1],
                               espn_game = sprintf("%s at %s", g$away_team_name[1], g$home_team_name[1])))
    tibble(orientation = "no ESPN game", neutral = NA, espn_game = NA)
  }))
  if (length(ev)) write_csv(flips %>% count(orientation, neutral, espn_game, name = "events"), res("orientation_2026_11_05.csv"))

  # 2025-26: share of D1 games with a stored market line, on days the feed was pulled (presence only)
  con <- ro("data/archive/ncaab_analytics_2026_final.db")
  cov <- dbGetQuery(con, "
    WITH d1 AS (SELECT team_id FROM teams WHERE conference_id IS NOT NULL),
         g AS (SELECT game_date, COALESCE(neutral_site, 0) AS neutral,
                      game_id IN (SELECT game_id FROM consensus_odds) AS has_line
               FROM games WHERE season = 2026 AND home_score + away_score > 0
                 AND home_team_id IN d1 AND away_team_id IN d1),
         days AS (SELECT game_date FROM g GROUP BY 1 HAVING AVG(has_line) > 0.5)
    SELECT neutral, COUNT(*) AS games, SUM(has_line) AS with_market_line FROM g
    WHERE game_date IN days GROUP BY 1")
  dbDisconnect(con)
  write_csv(cov %>% mutate(site = ifelse(neutral == 1, "neutral site", "home site"),
                           share = with_market_line / games), res("market_line_presence_2025_26.csv"))
}

# ---- 3. Type contract at the database boundary (public, in-memory demo) -------------------------------------
con <- dbConnect(SQLite(), ":memory:")
dbExecute(con, "CREATE TABLE teams (team_id TEXT PRIMARY KEY, conference TEXT)")
dbExecute(con, "INSERT INTO teams VALUES ('145', 'SEC'), ('2856', 'Big West')")
tf <- tempfile(fileext = ".csv")
writeLines(c("game_id,home_team_id,away_team_id", "401911249,145,2856"), tf)
guessed <- read_csv(tf, show_col_types = FALSE)
typed <- read_csv(tf, col_types = cols(.default = col_character()))
lookup <- function(v) nrow(dbGetQuery(con, "SELECT conference FROM teams WHERE team_id = ?", params = list(v)))
type_demo <- tibble(
  id_value = c("read_csv() default guess", "explicit col_character()", "R integer 145L", "R double 145"),
  r_class = c(class(guessed$home_team_id), class(typed$home_team_id), "integer", "numeric"),
  sqlite_sees = c(dbGetQuery(con, "SELECT CAST(? AS TEXT) AS x", params = list(guessed$home_team_id[1]))$x,
                  typed$home_team_id[1], "145", dbGetQuery(con, "SELECT CAST(? AS TEXT) AS x", params = list(145))$x),
  rows_matched = c(lookup(guessed$home_team_id[1]), lookup(typed$home_team_id[1]), lookup(145L), lookup(145))
)
dbDisconnect(con)
write_csv(type_demo, res("type_contract_demo.csv"))
print(type_demo)

# ---- 4. Conference-tournament detection: ESPN's flag vs a neutral-site rule (public) ------------------------
g <- cbb_games(c(2010:2019, 2022:2026))
# Selection Sunday = the Sunday before the first postseason game (First Four, NIT and the NCAA field all start after it)
sel_sunday <- g %>%
  filter(season_type == 3) %>%
  group_by(season) %>% summarise(first_ncaa = min(date), .groups = "drop") %>%
  mutate(selection_sunday = first_ncaa - ((as.integer(format(first_ncaa, "%u")) %% 7)),
         window_start = selection_sunday - 12)
ct <- g %>%
  inner_join(sel_sunday, by = "season") %>%
  mutate(espn_flag = !is.na(tournament_id) & conf_game == 1 & season_type == 2 &
           date >= as.Date(sprintf("%d-02-15", season)) & date <= selection_sunday,
         neutral_rule = neutral == 1 & conf_game == 1 & date >= window_start & date <= selection_sunday) %>%
  filter(espn_flag | neutral_rule)
detect <- ct %>%
  group_by(season) %>%
  summarise(espn_flagged = sum(espn_flag), caught_by_neutral_rule = sum(espn_flag & neutral_rule),
            missed_campus_site = sum(espn_flag & !neutral_rule & neutral == 0),
            missed_outside_window_only = sum(espn_flag & !neutral_rule & neutral == 1),
            neutral_rule_only = sum(neutral_rule & !espn_flag), .groups = "drop") %>%
  mutate(missed = espn_flagged - caught_by_neutral_rule, missed_share = missed / espn_flagged,
         ci_lo = wilson(missed, espn_flagged)[, "lo"], ci_hi = wilson(missed, espn_flagged)[, "hi"],
         label = sprintf("%d-%02d", season - 1, season %% 100))
pooled <- detect %>% filter(season != 2022) %>%
  summarise(season = NA, label = "Pooled (excl. 2021-22)", seasons = n(), espn_flagged = sum(espn_flagged),
            missed = sum(missed), missed_campus_site = sum(missed_campus_site)) %>%
  mutate(missed_share = missed / espn_flagged, ci_lo = wilson(missed, espn_flagged)[, "lo"],
         ci_hi = wilson(missed, espn_flagged)[, "hi"])
write_csv(bind_rows(detect, pooled), res("conf_tournament_detection.csv"))
print(bind_rows(detect, pooled) %>% select(label, espn_flagged, missed, missed_campus_site, neutral_rule_only,
                                           missed_share, ci_lo, ci_hi))
# Example campus-site games the neutral rule missed in 2025-26 (public ESPN names)
write_csv(ct %>% filter(season == 2026, espn_flag, !neutral_rule) %>%
            transmute(date, home = home_name, away = away_name, neutral, event = sub(" - .*", "", notes)) %>%
            arrange(date), res("conf_tournament_missed_2025_26.csv"))

# ---- Figures ------------------------------------------------------------------------------------------------
steps <- read_csv(res("cascade_steps.csv"), show_col_types = FALSE)
comp <- read_csv(res("mapping_composition.csv"), show_col_types = FALSE)
ab <- read_csv(res("ablation_summary.csv"), show_col_types = FALSE)
sweep <- read_csv(res("fuzzy_threshold_sweep.csv"), show_col_types = FALSE)
k <- function(u, s) {
  v <- steps$names[steps$universe == u & steps$step == s]
  if (length(v)) v else 0L
}
n_comp <- function(m) comp$rows_2026_27[comp$method == m]

# Figure 1: the resolution cascade, drawn as boxes and arrows
box <- function(x, y, label, w = 3.3, h = 0.62, fill = "white", col = cs_ink[["baseline"]], bold = FALSE) {
  tibble(x = x, y = y, label = label, w = w, h = h, fill = fill, col = col, bold = bold)
}
kp <- "KenPom 2026-27"
bt <- "Barttorvik 2026-27"
lane_l <- 2.2
lane_r <- 6.7
boxes <- bind_rows(
  box(lane_l, 9.0, "Ratings sites: KenPom, Barttorvik\n365 names each (Python)", fill = "#e8f0fb", bold = TRUE),
  box(lane_l, 7.9, sprintf("1  Manual row in the mapping table\nKenPom %d | Barttorvik %d", k(kp, "1 manual row"), k(bt, "1 manual row"))),
  box(lane_l, 6.9, sprintf("2  Hardcoded fix in code (36 entries)\n%d | %d", k(kp, "2 hardcoded fix"), k(bt, "2 hardcoded fix"))),
  box(lane_l, 5.9, sprintf("3  Exact ESPN name\n%d | %d", k(kp, "3 exact ESPN name"), k(bt, "3 exact ESPN name"))),
  box(lane_l, 4.9, sprintf("4  Substring: first ESPN name containing it\n%d | %d", k(kp, "4 substring"), k(bt, "4 substring")),
      fill = "#fdeee7", col = cs_pal[["orange"]]),
  box(lane_l, 3.9, sprintf("5  Prefix match\n%d | %d", k(kp, "5 prefix"), k(bt, "5 prefix")),
      fill = "#fdeee7", col = cs_pal[["orange"]]),
  box(lane_l, 2.75, "Collision guard: two names on one ESPN id\n-> exit 2, nothing written", w = 3.3, h = 0.7,
      fill = "#f3f3f1", col = cs_ink[["primary"]], bold = TRUE),
  box(lane_r, 9.0, "Market feed: The Odds API\n351 team names (R)", fill = "#e8f0fb", bold = TRUE),
  box(lane_r, 7.9, "1  Cached row in the mapping table\n(every name seen before)"),
  box(lane_r, 6.9, sprintf("2  Exact ESPN name or display name\n%d rows cached as EXACT", n_comp("EXACT"))),
  box(lane_r, 5.8, sprintf("3  Jaro-Winkler similarity >= 0.78\n%d rows cached as FUZZY. Below 0.78: a warning,\nno line for that game; %d names fixed by hand", n_comp("FUZZY"), n_comp("MANUAL")),
      h = 0.85, fill = "#fdeee7", col = cs_pal[["orange"]]),
  box(lane_r, 4.6, "4  Match the event to an ESPN game: the feed's\nhome/away first, then reversed (neutral sites);\nstore every line in ESPN's orientation", h = 0.85),
  box(4.45, 1.45, "ESPN team id (text): the one join key for games, ratings, predictions and grades",
      w = 7.8, h = 0.55, fill = "#e8f0fb", bold = TRUE),
  box(4.45, 0.55, sprintf("Mapping table (%d rows) exported daily to a seed CSV in git; an empty table reloads from it",
                          sum(comp$rows_2026_27)), w = 7.8, h = 0.5, fill = cs_ink[["surface"]])
)
arrows <- bind_rows(
  tibble(x = lane_l, xend = lane_l, y = c(8.69, 7.59, 6.59, 5.59, 4.59), yend = c(8.21, 7.21, 6.21, 5.21, 4.21)),
  tibble(x = lane_l, xend = lane_l, y = 3.59, yend = 3.10),
  tibble(x = lane_r, xend = lane_r, y = c(8.69, 7.59, 6.59, 5.375), yend = c(8.21, 7.21, 6.225, 5.025)),
  tibble(x = c(lane_l, lane_r), xend = c(3.4, 5.5), y = c(2.40, 4.175), yend = c(1.73, 1.73))
)
p1 <- ggplot() +
  geom_segment(data = arrows, aes(x = x, xend = xend, y = y, yend = yend), colour = cs_ink[["muted"]],
               linewidth = 0.6, arrow = arrow(length = unit(0.12, "cm"), type = "closed")) +
  geom_tile(data = boxes, aes(x = x, y = y, width = w, height = h, fill = I(fill), colour = I(col)),
            linewidth = 0.5) +
  geom_text(data = boxes %>% filter(!bold), aes(x = x, y = y, label = label), size = 2.9,
            colour = cs_ink[["primary"]], lineheight = 0.95) +
  geom_text(data = boxes %>% filter(bold), aes(x = x, y = y, label = label), size = 2.9, fontface = "bold",
            colour = cs_ink[["primary"]], lineheight = 0.95) +
  annotate("text", x = lane_l + 1.75, y = 4.4, label = "fuzzy\nsteps", hjust = 0, size = 2.7,
           colour = cs_pal[["orange"]], fontface = "bold", lineheight = 0.9) +
  annotate("text", x = lane_r - 1.75, y = 5.8, label = "fuzzy\nstep", hjust = 1, size = 2.7,
           colour = cs_pal[["orange"]], fontface = "bold", lineheight = 0.9) +
  annotate("text", x = lane_l + 1.75, y = 7.4, label = "explicit\nsteps", hjust = 0, size = 2.7,
           colour = cs_ink[["secondary"]], lineheight = 0.9) +
  scale_x_continuous(limits = c(0.45, 9.1), expand = c(0, 0)) +
  scale_y_continuous(limits = c(0.2, 9.4), expand = c(0, 0)) +
  labs(title = "Four sources, one key: a third of ratings-site names don't match ESPN's spelling",
       subtitle = "Each source name falls through the steps until one resolves it. Counts are 2026-27 names per step (KenPom | Barttorvik).\nWith exact matching alone, 126 of 365 KenPom names and 130 of 365 Barttorvik names find no team.",
       caption = "Source: the pipeline's resolvers (fetch_kenpom.py, odds_api.R) replayed on 2026-27 names; mapping table as of 2026-11-05.") +
  theme_void(base_size = 11) +
  theme(plot.background = element_rect(fill = cs_ink[["surface"]], colour = NA),
        plot.title = element_text(face = "bold", colour = cs_ink[["primary"]], size = rel(1.15)),
        plot.subtitle = element_text(colour = cs_ink[["secondary"]], margin = margin(b = 6)),
        plot.caption = element_text(colour = cs_ink[["muted"]], hjust = 0, size = rel(0.8)),
        plot.title.position = "plot", plot.caption.position = "plot", plot.margin = margin(12, 12, 10, 12))
save_fig(p1, fig("01_resolution_cascade.png"), width = 9.5, height = 7)

# Figure 2: what each part of the cascade is worth (ablation), KenPom 2026-27 and 2025-26
lab <- c(production = "Production (all steps)", last_season_rows = "Last season's manual rows",
         no_manual = "No manual rows", no_manual_no_fixes = "No manual rows, no code fixes",
         fuzzy_off = "Fuzzy steps off", exact_only = "Exact ESPN name only")
ab2 <- ab %>%
  filter(universe %in% c("KenPom 2025-26", "KenPom 2026-27")) %>%
  transmute(universe, variant = factor(lab[variant], levels = rev(lab)),
            `Unresolved\n(logged; team skipped)` = unresolved,
            `Wrong: collision guard\nstops the run` = wrong_caught_by_collision,
            `Wrong: only a D1 check\nwould catch it (not built)` = wrong_caught_by_d1 + wrong_caught_by_conference,
            `Wrong: no check\ncatches it` = wrong_silent) %>%
  pivot_longer(-c(universe, variant), names_to = "outcome", values_to = "names") %>%
  mutate(outcome = factor(outcome, levels = unique(outcome)))
write_csv(ab2 %>% mutate(outcome = gsub("\n", " ", outcome)), res("fig02_ablation_long.csv"))
p2 <- ggplot(ab2 %>% mutate(kind = ifelse(grepl("^Unresolved", outcome), "unresolved", "wrong")),
             aes(x = names, y = variant, fill = kind)) +
  geom_col(width = 0.65) +
  geom_text(aes(label = names), hjust = -0.25, size = 3, colour = cs_ink[["secondary"]]) +
  facet_grid(universe ~ outcome, scales = "free_x") +
  scale_fill_manual(values = c(unresolved = cs_pal[["blue"]], wrong = cs_pal[["orange"]]), guide = "none") +
  scale_x_continuous(expand = expansion(mult = c(0, 0.3)), breaks = function(l) unique(floor(pretty(l, 3)))) +
  labs(title = "Without the manual rows, names go missing loudly, except one that goes wrong silently",
       subtitle = "KenPom names (365 per season) replayed through the production resolver with parts of the cascade removed",
       x = "Names", y = NULL,
       caption = paste("No check catches Mississippi -> Mississippi State: both are SEC teams, and nothing else claims that id.",
                       "\nD1 check = the resolved ESPN team has a D1 conference (Regis, Hawai'i Pacific fail it). Source: fetch_kenpom.resolve_team_id,",
                       "2025-26 and 2026-27 names.")) +
  theme_cs() +
  theme(panel.grid.major.y = element_blank(), panel.spacing.x = unit(1.2, "lines"),
        strip.text.y = element_text(angle = 0, hjust = 0))
save_fig(p2, fig("02_cascade_ablation.png"), width = 11.5, height = 5.6)

# Figure 3: no fuzzy threshold is both safe and complete (market feed, 2025-26 team universe)
sw <- sweep %>% filter(universe == "ESPN teams 2025-26") %>%
  select(threshold, wrong, unmatched) %>%
  pivot_longer(-threshold, names_to = "outcome", values_to = "names") %>%
  mutate(outcome = recode(outcome, wrong = "Matched to the wrong team", unmatched = "Left unmatched"))
p3 <- ggplot(sw, aes(threshold, names, colour = outcome)) +
  annotate("rect", xmin = 0.78, xmax = 0.85, ymin = -Inf, ymax = Inf, fill = cs_ink[["grid"]], alpha = 0.5) +
  geom_step(linewidth = 0.9) +
  geom_point(data = sw %>% filter(threshold %in% c(0.78, 0.85)), size = 2.2) +
  annotate("text", x = 0.781, y = 52, hjust = 0, size = 3, colour = cs_ink[["secondary"]], lineheight = 0.95,
           label = "Lowering 0.85 to 0.78 (for\nCal State spellings) lets\nSt. Thomas (MN) match\nSt. Thomas (TX) at 0.82") +
  scale_colour_manual(values = c("Left unmatched" = cs_pal[["blue"]],
                                 "Matched to the wrong team" = cs_pal[["orange"]])) +
  scale_x_continuous(breaks = seq(0.70, 0.95, 0.05)) +
  labs(title = "No similarity threshold is both safe and complete",
       subtitle = "Market-feed team names (351) matched to ESPN teams by Jaro-Winkler similarity, by threshold",
       x = "Similarity threshold", y = "Names",
       caption = paste("Truth = the current hand-checked mapping. Exact matches (284) come first and are always right.",
                       "\nSource: replay of odds_api.R against the 730 ESPN teams on 2025-26 schedules. Shaded: 0.78 (production) to 0.85.")) +
  theme_cs()
save_fig(p3, fig("03_fuzzy_threshold.png"))

# Figure 4: conference-tournament games a neutral-site rule misses, by season
d4 <- detect %>% mutate(label = factor(label, levels = label),
                        flag_ok = ifelse(season == 2022, "ESPN's flag incomplete", "ok"))
p4 <- ggplot(d4, aes(label, missed_share, colour = flag_ok)) +
  geom_hline(yintercept = pooled$missed_share, colour = cs_ink[["baseline"]], linewidth = 0.6, linetype = "22") +
  geom_errorbar(aes(ymin = ci_lo, ymax = ci_hi), width = 0, linewidth = 0.8) +
  geom_point(size = 2.4) +
  annotate("text", x = which(levels(d4$label) == "2021-22"), y = 0.012, size = 2.8, colour = cs_ink[["muted"]],
           label = "ESPN flag\nincomplete", lineheight = 0.9) +
  scale_colour_manual(values = c(ok = cs_pal[["blue"]], `ESPN's flag incomplete` = cs_ink[["muted"]]), guide = "none") +
  annotate("text", x = which(levels(d4$label) == "2021-22"), y = pooled$missed_share, vjust = -0.6, size = 3, colour = cs_ink[["secondary"]],
           label = sprintf("pooled %.1f%%", 100 * pooled$missed_share)) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1), limits = c(0, NA)) +
  labs(title = sprintf("A neutral-site rule misses about 1 in %d conference-tournament games",
                       round(1 / pooled$missed_share)),
       subtitle = "Share of ESPN-tagged conference-tournament games that the old rule (neutral site, last 12 days\nbefore Selection Sunday) misses, with 95% Wilson intervals",
       x = NULL, y = "Missed",
       caption = sprintf("%d of %d misses are campus-site games. Pooled line excludes 2021-22 (%s games). 2019-20 and 2020-21 omitted.\nSource: ESPN via hoopR.",
                         pooled$missed_campus_site, pooled$missed, scales::comma(pooled$espn_flagged))) +
  theme_cs() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))
save_fig(p4, fig("04_conf_tournament_detection.png"), width = 8.5, height = 4.8)
cat("study 09 done\n")
