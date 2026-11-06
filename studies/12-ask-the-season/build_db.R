# Builds data/ask/season.db (gitignored) from the public ESPN cache only: seven seasons (2019-20 to 2025-26) of
# games, team box scores, team-season summaries with a public rating, and conferences derived from the schedule.
#   Rscript studies/12-ask-the-season/build_db.R      (from the repo root; about 30 seconds on a warm cache)
suppressPackageStartupMessages({
  library(dplyr)
  library(DBI)
  library(RSQLite)
})
source("R/data.R")
source("R/ratings.R")

seasons <- 2020:2026
out_path <- file.path(cs_root(), "data", "ask", "season.db")
dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)

games_raw <- suppressMessages(cbb_games(seasons))
box_raw <- suppressMessages(cbb_team_box(seasons))

# ---- conferences: connected components of the regular-season conference-game graph, named from tournament notes
conf_patterns <- c(
  "america east" = "America East", "american" = "American", "\\bacc\\b" = "ACC", "atlantic 10|\\ba-10\\b" = "Atlantic 10",
  "asun|atlantic sun" = "ASUN", "big 12" = "Big 12", "big east" = "Big East", "big sky" = "Big Sky",
  "big south" = "Big South", "big ten" = "Big Ten", "big west" = "Big West", "\\bcaa\\b|colonial" = "CAA",
  "c-?usa|conference usa" = "Conference USA", "horizon" = "Horizon League", "ivy" = "Ivy League",
  "maac|metro atlantic" = "MAAC", "\\bmac\\b|mid-american" = "MAC", "meac" = "MEAC",
  "mountain west" = "Mountain West", "\\bmvc\\b|missouri valley" = "Missouri Valley",
  "northeast|\\bnec\\b" = "Northeast", "\\bovc\\b|ohio valley" = "Ohio Valley", "pac-?12" = "Pac-12",
  "patriot" = "Patriot League", "\\bsec\\b" = "SEC", "socon|southern conference" = "SoCon",
  "southland" = "Southland", "summit" = "Summit League", "sun belt" = "Sun Belt", "swac" = "SWAC",
  "\\bwac\\b|western athletic" = "WAC", "west coast|\\bwcc\\b" = "West Coast"
)
conf_name <- function(note) {
  pre <- tolower(sub(" - .*", "", note))
  for (p in names(conf_patterns)) if (grepl(p, pre)) return(conf_patterns[[p]])
  NA_character_
}

components <- function(edges) {
  ids <- unique(c(edges$home_id, edges$away_id))
  parent <- setNames(ids, ids)
  find <- function(x) { while (parent[[x]] != x) x <- parent[[x]]; x }
  for (i in seq_len(nrow(edges))) {
    a <- find(edges$home_id[i]); b <- find(edges$away_id[i])
    if (a != b) parent[[a]] <- b
  }
  tibble(team_id = ids, comp = vapply(ids, find, ""))
}

conf_by_season <- bind_rows(lapply(seasons, function(s) {
  gs <- games_raw %>% filter(season == s, season_type == 2, home_d1, away_d1)
  cc <- components(gs %>% filter(conf_game == 1) %>% select(home_id, away_id))
  votes <- gs %>%
    filter(conf_game == 1, grepl(" - ", notes), grepl("tournament|championship|playoff", notes, ignore.case = TRUE)) %>%
    mutate(conf = vapply(notes, conf_name, "")) %>%
    filter(!is.na(conf)) %>%
    inner_join(cc, by = c("home_id" = "team_id")) %>%
    count(comp, conf) %>%
    group_by(comp) %>% slice_max(n, n = 1, with_ties = FALSE) %>% ungroup()
  cc %>% left_join(votes %>% select(comp, conf), by = "comp") %>%
    group_by(comp) %>%
    mutate(conf = coalesce(conf, paste0("Unnamed conference ", s, "-", match(comp[1], unique(cc$comp))))) %>%
    ungroup() %>%
    transmute(season = as.integer(s), team_id, conference = conf)
}))

# A conference whose tournament never tipped (2019-20 was cancelled mid-March) takes the name its members carry in
# the nearest season that has one.
named <- conf_by_season %>% filter(!grepl("^Unnamed", conference))
fill <- conf_by_season %>% filter(grepl("^Unnamed", conference)) %>%
  inner_join(named %>% rename(other_season = season, other_conf = conference), by = "team_id",
             relationship = "many-to-many") %>%
  group_by(season, conference) %>%
  filter(abs(other_season - season) == min(abs(other_season - season))) %>%
  count(other_conf) %>% slice_max(n, n = 1, with_ties = FALSE) %>% ungroup() %>%
  select(season, conference, other_conf)
conf_by_season <- conf_by_season %>% left_join(fill, by = c("season", "conference")) %>%
  mutate(conference = coalesce(other_conf, conference)) %>% select(-other_conf)
stopifnot(!any(duplicated(conf_by_season[c("season", "team_id")])))
stopifnot(!any(duplicated(distinct(conf_by_season, season, conference, team_id)[c("season", "team_id")])))

# ---- games
games <- games_raw %>%
  mutate(
    game_type = case_when(
      season_type == 3 & grepl("Men's Basketball Championship", notes, fixed = TRUE) ~ "ncaa_tournament",
      season_type == 3 ~ "other_postseason",
      conf_game == 1 & grepl(" - ", notes) & grepl("tournament|championship|playoff", notes, ignore.case = TRUE) ~
        "conf_tournament",
      TRUE ~ "regular"
    ),
    tourney_round = ifelse(game_type == "ncaa_tournament", sub(".* - ", "", notes), NA_character_),
    date = format(date, "%Y-%m-%d"),
    home_d1 = as.integer(home_d1), away_d1 = as.integer(away_d1)
  ) %>%
  select(game_id, season, date, season_type, game_type, tourney_round, home_id, away_id, home_name, away_name,
         home_score, away_score, margin, neutral, conf_game, ot_periods, attendance, notes, home_d1, away_d1)

# ---- team_games (box scores), one row per team per game
team_games <- box_raw %>%
  semi_join(games, by = "game_id") %>%
  mutate(date = format(date, "%Y-%m-%d"), win = as.integer(pts > opp_pts), poss = round(poss, 2)) %>%
  select(game_id, season, date, season_type, team_id, opp_id, home_away, win, pts, opp_pts, fgm, fga, fg3m, fg3a,
         ftm, fta, orb, drb, tov, poss)

# ---- teams: every team that appears in a game; latest display name; latest D1 conference
names_long <- bind_rows(
  games %>% transmute(team_id = home_id, name = home_name, season, date),
  games %>% transmute(team_id = away_id, name = away_name, season, date)
)
teams <- names_long %>%
  group_by(team_id) %>%
  arrange(desc(date), .by_group = TRUE) %>%
  summarise(name = first(name), first_season = min(season), last_season = max(season), .groups = "drop") %>%
  left_join(conf_by_season %>% group_by(team_id) %>% slice_max(season, n = 1) %>% ungroup() %>%
              select(team_id, conference), by = "team_id") %>%
  arrange(name)

# ---- team_seasons: D1 teams only (those with a derived conference that season)
long <- bind_rows(
  games %>% transmute(season, game_id, game_type, team_id = home_id, opp_id = away_id, pts = home_score,
                      opp_pts = away_score, conf_game, ot_periods),
  games %>% transmute(season, game_id, game_type, team_id = away_id, opp_id = home_id, pts = away_score,
                      opp_pts = home_score, conf_game, ot_periods)
)
record <- long %>%
  group_by(season, team_id) %>%
  summarise(games = n(), wins = sum(pts > opp_pts), losses = sum(pts < opp_pts),
            conf_wins = sum(pts > opp_pts & conf_game == 1 & game_type == "regular"),
            conf_losses = sum(pts < opp_pts & conf_game == 1 & game_type == "regular"),
            ppg = round(mean(pts), 1), opp_ppg = round(mean(opp_pts), 1), .groups = "drop")

box_pair <- team_games %>%
  inner_join(team_games %>% select(game_id, team_id, o_fgm = fgm, o_fga = fga, o_fg3m = fg3m, o_fg3a = fg3a,
                                   o_fta = fta, o_orb = orb, o_drb = drb, o_tov = tov, o_poss = poss),
             by = c("game_id", "opp_id" = "team_id")) %>%
  inner_join(games %>% select(game_id, ot_periods), by = "game_id")
four <- box_pair %>%
  group_by(season, team_id) %>%
  summarise(
    box_games = n(),
    tempo = round(mean((poss + o_poss) / 2 * 40 / (40 + 5 * ot_periods)), 1),
    off_eff = round(100 * sum(pts) / sum((poss + o_poss) / 2), 1),
    def_eff = round(100 * sum(opp_pts) / sum((poss + o_poss) / 2), 1),
    efg_pct = round(100 * sum(fgm + 0.5 * fg3m) / sum(fga), 1),
    tov_pct = round(100 * sum(tov) / sum(poss), 1),
    orb_pct = round(100 * sum(orb) / sum(orb + o_drb), 1),
    ft_rate = round(100 * sum(fta) / sum(fga), 1),
    fg3_rate = round(100 * sum(fg3a) / sum(fga), 1),
    fg3_pct = round(100 * sum(fg3m) / sum(fg3a), 1),
    opp_efg_pct = round(100 * sum(o_fgm + 0.5 * o_fg3m) / sum(o_fga), 1),
    opp_tov_pct = round(100 * sum(o_tov) / sum(o_poss), 1),
    drb_pct = round(100 * sum(drb) / sum(drb + o_orb), 1),
    opp_ft_rate = round(100 * sum(o_fta) / sum(o_fga), 1),
    .groups = "drop"
  ) %>%
  mutate(net_eff = round(off_eff - def_eff, 1))

fits <- lapply(seasons, function(s) fit_ratings(games_raw %>% filter(season == s, season_type == 2)))
ratings <- bind_rows(lapply(seq_along(seasons), function(i) {
  fits[[i]]$ratings %>% transmute(season = as.integer(seasons[i]), team_id, rating = round(rating, 2))
})) %>%
  group_by(season) %>% mutate(rating_rank = as.integer(rank(-rating, ties.method = "min"))) %>% ungroup()

team_seasons <- conf_by_season %>%
  left_join(record, by = c("season", "team_id")) %>%
  left_join(four, by = c("season", "team_id")) %>%
  left_join(ratings, by = c("season", "team_id")) %>%
  left_join(teams %>% select(team_id, name), by = "team_id") %>%
  select(season, team_id, name, conference, games, wins, losses, conf_wins, conf_losses, ppg, opp_ppg, rating,
         rating_rank, tempo, off_eff, def_eff, net_eff, efg_pct, tov_pct, orb_pct, ft_rate, fg3_rate, fg3_pct,
         opp_efg_pct, opp_tov_pct, drb_pct, opp_ft_rate, box_games) %>%
  arrange(season, rating_rank)

season_tbl <- tibble(
  season = as.integer(seasons),
  label = sprintf("%d-%02d", seasons - 1, seasons %% 100),
  hca = round(vapply(fits, `[[`, 0, "hca"), 2),
  sigma = round(vapply(fits, `[[`, 0, "sigma"), 2),
  rating_games = vapply(fits, `[[`, 0L, "n_games"),
  first_date = vapply(seasons, function(s) min(games$date[games$season == s]), ""),
  last_date = vapply(seasons, function(s) max(games$date[games$season == s]), "")
)

# ---- write
if (file.exists(out_path)) invisible(file.remove(out_path))
con <- dbConnect(SQLite(), out_path)
ddl <- c(
  "CREATE TABLE seasons (season INTEGER PRIMARY KEY, label TEXT NOT NULL, hca REAL, sigma REAL,
     rating_games INTEGER, first_date TEXT, last_date TEXT)",
  "CREATE TABLE teams (team_id TEXT PRIMARY KEY, name TEXT NOT NULL, conference TEXT, first_season INTEGER,
     last_season INTEGER)",
  "CREATE TABLE games (game_id TEXT PRIMARY KEY, season INTEGER NOT NULL, date TEXT NOT NULL,
     season_type INTEGER NOT NULL, game_type TEXT NOT NULL, tourney_round TEXT, home_id TEXT NOT NULL,
     away_id TEXT NOT NULL, home_name TEXT, away_name TEXT, home_score INTEGER, away_score INTEGER,
     margin INTEGER, neutral INTEGER, conf_game INTEGER, ot_periods INTEGER, attendance INTEGER, notes TEXT,
     home_d1 INTEGER, away_d1 INTEGER)",
  "CREATE TABLE team_games (game_id TEXT NOT NULL, season INTEGER NOT NULL, date TEXT NOT NULL,
     season_type INTEGER NOT NULL, team_id TEXT NOT NULL, opp_id TEXT NOT NULL, home_away TEXT, win INTEGER,
     pts INTEGER, opp_pts INTEGER, fgm INTEGER, fga INTEGER, fg3m INTEGER, fg3a INTEGER, ftm INTEGER,
     fta INTEGER, orb INTEGER, drb INTEGER, tov INTEGER, poss REAL, PRIMARY KEY (game_id, team_id))",
  "CREATE TABLE team_seasons (season INTEGER NOT NULL, team_id TEXT NOT NULL, name TEXT, conference TEXT,
     games INTEGER, wins INTEGER, losses INTEGER, conf_wins INTEGER, conf_losses INTEGER, ppg REAL,
     opp_ppg REAL, rating REAL, rating_rank INTEGER, tempo REAL, off_eff REAL, def_eff REAL, net_eff REAL,
     efg_pct REAL, tov_pct REAL, orb_pct REAL, ft_rate REAL, fg3_rate REAL, fg3_pct REAL, opp_efg_pct REAL,
     opp_tov_pct REAL, drb_pct REAL, opp_ft_rate REAL, box_games INTEGER, PRIMARY KEY (season, team_id))"
)
for (d in ddl) invisible(dbExecute(con, gsub("\\s+", " ", d)))
int_cols <- function(df) { for (c in names(df)) if (is.numeric(df[[c]]) && all(df[[c]] == round(df[[c]]), na.rm = TRUE) &&
                                                   !c %in% c("rating", "poss", "hca", "sigma")) df[[c]] <- as.integer(df[[c]]); df }
invisible(dbAppendTable(con, "seasons", as.data.frame(season_tbl)))
invisible(dbAppendTable(con, "teams", as.data.frame(int_cols(teams))))
invisible(dbAppendTable(con, "games", as.data.frame(int_cols(games))))
invisible(dbAppendTable(con, "team_games", as.data.frame(int_cols(team_games))))
invisible(dbAppendTable(con, "team_seasons", as.data.frame(team_seasons)))
for (ix in c("CREATE INDEX ix_games_season ON games(season)", "CREATE INDEX ix_games_home ON games(home_id)",
             "CREATE INDEX ix_games_away ON games(away_id)", "CREATE INDEX ix_games_date ON games(date)",
             "CREATE INDEX ix_tg_team ON team_games(team_id, season)", "CREATE INDEX ix_ts_name ON team_seasons(name)"))
  invisible(dbExecute(con, ix))
invisible(dbExecute(con, "ANALYZE"))
counts <- sapply(c("seasons", "teams", "games", "team_games", "team_seasons"),
                 function(t) dbGetQuery(con, paste("SELECT COUNT(*) n FROM", t))$n)
dbDisconnect(con)

cat("wrote", out_path, "\n")
print(counts)
cat("conferences per season:\n")
print(conf_by_season %>% count(season, name = "n_conferences_x_teams") %>%
        left_join(conf_by_season %>% distinct(season, conference) %>% count(season, name = "conferences"), by = "season"))
unnamed <- conf_by_season %>% filter(grepl("^Unnamed", conference)) %>% distinct(season, conference)
if (nrow(unnamed)) { cat("unnamed components:\n"); print(unnamed) }
