# Public data layer: ESPN men's college basketball via hoopR (sportsdataverse release files).
# Seasons are named by their ending year (2026 = 2025-26). Everything is cached under data/cache/ (gitignored),
# so a study re-runs offline once the cache is warm. D1 = a team with an ESPN conference id that season.
suppressPackageStartupMessages({
  library(dplyr)
  library(hoopR)
})

cs_root <- function() {
  d <- normalizePath(getwd())
  while (!file.exists(file.path(d, "R", "data.R"))) {
    up <- dirname(d)
    if (up == d) stop("run from inside the ncaab-analytics-case-studies repo")
    d <- up
  }
  d
}

.cache_path <- function(kind, season) {
  dir <- file.path(cs_root(), "data", "cache")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  file.path(dir, sprintf("%s_%d.rds", kind, season))
}

# refresh = TRUE rebuilds the cache (use it for the season in progress). Writes are atomic (temp file + rename),
# so a reader in another process never sees a half-written file.
.cached <- function(kind, season, build, refresh = FALSE) {
  path <- .cache_path(kind, season)
  if (!refresh && file.exists(path)) return(readRDS(path))
  out <- build()
  tmp <- paste0(path, ".tmp", Sys.getpid())
  saveRDS(out, tmp)
  file.rename(tmp, path)
  out
}

.num <- function(x) suppressWarnings(as.numeric(x))

#' Completed games for the given seasons, one row per game.
cbb_games <- function(seasons, refresh = FALSE) {
  bind_rows(lapply(seasons, function(s) .cached("games", s, refresh = refresh, build = function() {
    x <- load_mbb_schedule(seasons = s)
    for (col in c("status_period", "venue_id", "tournament_id", "notes_headline", "attendance")) {
      if (!col %in% names(x)) x[[col]] <- NA   # older seasons lack some ESPN fields
    }
    d1 <- unique(c(x$home_id[!is.na(x$home_conference_id)], x$away_id[!is.na(x$away_conference_id)]))
    x %>%
      filter(coalesce(status_type_completed, FALSE)) %>%
      transmute(
        season = as.integer(s),
        game_id = as.character(game_id),
        date = as.Date(substr(as.character(game_date), 1, 10)),
        season_type = as.integer(season_type),
        home_id = as.character(home_id), away_id = as.character(away_id),
        home_name = home_display_name, away_name = away_display_name,
        home_score = as.integer(home_score), away_score = as.integer(away_score),
        margin = home_score - away_score,
        neutral = as.integer(coalesce(as.logical(neutral_site), FALSE)),
        conf_game = as.integer(coalesce(as.logical(conference_competition), FALSE)),
        # attendance: NA when ESPN has 0 or nothing. attendance_raw keeps ESPN's 0, which in 2020-21 mostly means
        # an empty arena (2,405 zeros that season vs 362 in 2018-19, when a 0 is usually just missing).
        attendance_raw = as.integer(attendance),
        attendance = ifelse(is.na(attendance_raw) | attendance_raw <= 0, NA_integer_, attendance_raw),
        ot_periods = pmax(0L, as.integer(status_period) - 2L),
        tournament_id = as.character(tournament_id),
        notes = as.character(notes_headline),
        venue_id = as.character(venue_id),
        home_d1 = home_id %in% d1, away_d1 = away_id %in% d1
      ) %>%
      filter(!is.na(home_score), !is.na(away_score), home_score + away_score > 0) %>%
      distinct(game_id, .keep_all = TRUE)
  })))
}

#' Team box scores, one row per team per game, with an estimated possession count.
cbb_team_box <- function(seasons, refresh = FALSE) {
  bind_rows(lapply(seasons, function(s) .cached("team_box", s, refresh = refresh, build = function() {
    load_mbb_team_box(seasons = s) %>%
      transmute(
        season = as.integer(s),
        game_id = as.character(game_id),
        date = as.Date(substr(as.character(game_date), 1, 10)),
        season_type = as.integer(season_type),
        team_id = as.character(team_id), opp_id = as.character(opponent_team_id),
        home_away = as.character(team_home_away),
        pts = .num(team_score), opp_pts = .num(opponent_team_score),
        fgm = .num(field_goals_made), fga = .num(field_goals_attempted),
        fg3m = .num(three_point_field_goals_made), fg3a = .num(three_point_field_goals_attempted),
        ftm = .num(free_throws_made), fta = .num(free_throws_attempted),
        orb = .num(offensive_rebounds), drb = .num(defensive_rebounds),
        tov = .num(coalesce(total_turnovers, turnovers)),
        poss = fga - orb + tov + 0.475 * fta
      ) %>%
      filter(!is.na(fga), fga > 0) %>%
      distinct(game_id, team_id, .keep_all = TRUE)
  })))
}

#' Player minutes, one row per player per game played.
cbb_player_box <- function(seasons, refresh = FALSE) {
  bind_rows(lapply(seasons, function(s) .cached("player_box", s, refresh = refresh, build = function() {
    p <- load_mbb_player_box(seasons = s)
    if ("did_not_play" %in% names(p)) p <- p %>% filter(!coalesce(as.logical(did_not_play), FALSE))
    p %>%
      transmute(
        season = as.integer(s),
        game_id = as.character(game_id),
        date = as.Date(substr(as.character(game_date), 1, 10)),
        team_id = as.character(team_id),
        athlete_id = as.character(athlete_id),
        athlete_name = as.character(athlete_display_name),
        minutes = .num(minutes)
      ) %>%
      filter(!is.na(athlete_id), !is.na(minutes), minutes > 0)
  })))
}

#' D1 vs D1 games only (both teams have a conference id that season).
d1_only <- function(games) games %>% filter(home_d1, away_d1)
