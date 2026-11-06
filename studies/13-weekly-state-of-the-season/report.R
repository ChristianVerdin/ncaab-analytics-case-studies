# Weekly "state of the season" report from public data only (ESPN via hoopR). No betting content.
#
#   Rscript studies/13-weekly-state-of-the-season/report.R --season 2026 --asof 2026-02-23
#   Rscript studies/13-weekly-state-of-the-season/report.R --season 2027 --asof 2026-12-07 --refresh --out /path/STATE.md
#
# --asof is the report date: only games played before it count. --refresh re-downloads the season (use it for
# the season in progress). Without --out, it writes the committed sample under studies/13-.../sample/.
# Writes the markdown report plus figures/ next to it, and results/ CSVs for the sample.
suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
})
source("R/data.R")
source("R/ratings.R")
source("R/theme.R")

arg <- function(flag, default = NULL) {
  a <- commandArgs(trailingOnly = TRUE)
  i <- match(flag, a)
  if (is.na(i)) return(default)
  if (i == length(a) || startsWith(a[i + 1], "--")) return(TRUE)
  a[i + 1]
}
season <- as.integer(arg("--season", 2026))
asof <- as.Date(arg("--asof", as.character(Sys.Date())))
refresh <- isTRUE(arg("--refresh", FALSE))
study_dir <- "studies/13-weekly-state-of-the-season"
out <- arg("--out", file.path(study_dir, "sample", sprintf("STATE_OF_THE_SEASON_%s.md", asof)))
out_dir <- dirname(out)
fig_dir <- file.path(out_dir, "figures")
is_sample <- is.null(arg("--out"))
label <- sprintf("%d-%02d", season - 1, season %% 100)
min_games <- 5

games <- cbb_games(season, refresh = refresh) %>% filter(date < asof)
box <- cbb_team_box(season, refresh = refresh) %>% filter(date < asof)
d1g <- d1_only(games)
too_early <- function(msg) { cat(msg, "\n"); quit(save = "no", status = 75) }   # 75 = skip in daily_update.sh
if (nrow(d1g) < 50) too_early(sprintf("only %d D1 games before %s; too early for a report", nrow(d1g), asof))
n_ready <- sum(table(c(d1g$home_id, d1g$away_id)) >= min_games)
if (n_ready < 100) too_early(sprintf("only %d teams with %d+ D1 games before %s; too early", n_ready, min_games, asof))

# team names and conferences (a team's conference = the ESPN group of its conference games)
names_df <- bind_rows(games %>% select(team_id = home_id, team = home_name),
                      games %>% select(team_id = away_id, team = away_name)) %>% distinct(team_id, .keep_all = TRUE)
sched <- hoopR::load_mbb_schedule(seasons = season)
conf_df <- bind_rows(
  sched %>% filter(coalesce(conference_competition, FALSE)) %>% transmute(team_id = as.character(home_id), conf = groups_short_name),
  sched %>% filter(coalesce(conference_competition, FALSE)) %>% transmute(team_id = as.character(away_id), conf = groups_short_name)
) %>% filter(!is.na(conf)) %>% count(team_id, conf) %>% group_by(team_id) %>% slice_max(n, n = 1, with_ties = FALSE) %>%
  ungroup() %>% select(team_id, conf)

fit_now <- fit_ratings(d1g)
fit_prev <- tryCatch(fit_ratings(d1g, before = asof - 7), error = function(e) NULL)
if (is.null(fit_prev)) fit_prev <- list(ratings = tibble(team_id = character(), rating = numeric()))
sigma <- fit_now$sigma

# per-team game log (D1 vs D1) with ratings-based win probabilities
r_now <- setNames(fit_now$ratings$rating, fit_now$ratings$team_id)
glog <- bind_rows(
  d1g %>% transmute(game_id, date, team_id = home_id, opp_id = away_id, pts = home_score, opp = away_score,
                    site = ifelse(neutral == 1, 0, 1), ot = ot_periods),
  d1g %>% transmute(game_id, date, team_id = away_id, opp_id = home_id, pts = away_score, opp = home_score,
                    site = ifelse(neutral == 1, 0, -1), ot = ot_periods)
) %>%
  mutate(win = as.integer(pts > opp),
         exp_margin = r_now[team_id] - r_now[opp_id] + fit_now$hca * site,
         p_win = pnorm(exp_margin / sigma),
         close = abs(pts - opp) <= 4 | ot > 0)

# full records include non-D1 games
rec <- bind_rows(games %>% transmute(team_id = home_id, win = home_score > away_score),
                 games %>% transmute(team_id = away_id, win = away_score > home_score)) %>%
  group_by(team_id) %>% summarise(w = sum(win), l = sum(!win), .groups = "drop")

eff <- box %>%
  left_join(box %>% select(game_id, opp_id = team_id, opp_poss = poss), by = c("game_id", "opp_id")) %>%
  filter(team_id %in% names(r_now)) %>%
  group_by(team_id) %>%
  summarise(off = 100 * sum(pts) / sum(poss), def = 100 * sum(opp_pts) / sum(opp_poss, na.rm = TRUE),
            tempo = mean((poss + opp_poss) / 2, na.rm = TRUE), three_rate = sum(fg3a) / sum(fga), .groups = "drop")

teams <- fit_now$ratings %>%
  rename(rating = rating, d1_games = games) %>%
  left_join(fit_prev$ratings %>% select(team_id, rating_prev = rating), by = "team_id") %>%
  left_join(names_df, by = "team_id") %>%
  left_join(conf_df, by = "team_id") %>%
  left_join(rec, by = "team_id") %>%
  left_join(glog %>% group_by(team_id) %>%
              summarise(sos = mean(r_now[opp_id]), luck = sum(win) - sum(p_win),
                        close_w = sum(win[close]), close_l = sum(!win[close]), .groups = "drop"), by = "team_id") %>%
  left_join(eff, by = "team_id") %>%
  mutate(rank = rank(-rating, ties.method = "first"),
         rank_prev = rank(-coalesce(rating_prev, -Inf), ties.method = "first"),
         change = rating - rating_prev,
         record = sprintf("%d-%d", w, l),
         conf = coalesce(conf, "—")) %>%
  arrange(rank)

fmt <- function(x, d = 1) formatC(x, format = "f", digits = d)
signed <- function(x, d = 1) {
  x <- round(x, d)
  ifelse(is.na(x), "new", ifelse(x > 0, paste0("+", fmt(x, d)), ifelse(x == 0, fmt(0, d), fmt(x, d))))
}
md_table <- function(df) {
  df[] <- lapply(df, function(col) trimws(as.character(col)))
  c(paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
    apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |")))
}
eligible <- teams %>% filter(d1_games >= min_games)

top25 <- eligible %>% slice_min(rank, n = 25) %>%
  transmute(Rank = rank, Team = team, Conf = conf, Record = record, Rating = fmt(rating),
            `Week` = ifelse(is.na(rating_prev), "new", sprintf("%s (%s)", signed(change), signed(rank_prev - rank, 0))),
            SOS = fmt(sos))
movers <- eligible %>% filter(!is.na(change)) %>% arrange(desc(change))
up <- head(movers, 5)
down <- tail(movers, 5) %>% arrange(change)
luckiest <- eligible %>% arrange(desc(luck)) %>% head(5)
unluckiest <- eligible %>% arrange(luck) %>% head(5)
conf_tbl <- eligible %>% filter(conf != "—") %>% group_by(conf) %>%
  summarise(teams = n(), mean_rating = mean(rating), best = team[which.max(rating)],
            top50 = sum(rank <= 50), .groups = "drop") %>% arrange(desc(mean_rating))

# figures
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
mv <- bind_rows(up, down) %>% mutate(team = factor(team, levels = rev(team)), dir = ifelse(change > 0, "Rose", "Fell"))
p1 <- ggplot(mv, aes(y = team)) +
  geom_segment(aes(x = rating_prev, xend = rating, yend = team), colour = cs_ink[["muted"]], linewidth = 0.8,
               arrow = arrow(length = unit(0.12, "cm"))) +
  geom_point(aes(x = rating_prev), colour = cs_ink[["baseline"]], size = 2.2) +
  geom_point(aes(x = rating, colour = dir), size = 2.6) +
  scale_colour_manual(values = c(Rose = cs_pal[["blue"]], Fell = cs_pal[["orange"]])) +
  labs(title = sprintf("Biggest rating moves in the week before %s", format(asof, "%b %-d")),
       subtitle = "Public rating (points vs an average D1 team), a week ago (gray) to now", x = "Rating", y = NULL,
       caption = sprintf("Ridge ratings on %s D1 games before %s. ESPN via hoopR.", format(nrow(d1g), big.mark = ","), asof)) +
  theme_cs()
save_fig(p1, file.path(fig_dir, sprintf("movers_%s.png", asof)), width = 8, height = 4.8)

ct <- eligible %>% filter(conf %in% head(conf_tbl$conf, 12)) %>%
  mutate(conf = factor(conf, levels = rev(head(conf_tbl$conf, 12))))
p2 <- ggplot(ct, aes(x = rating, y = conf)) +
  geom_point(colour = cs_pal[["blue"]], alpha = 0.35, size = 2) +
  stat_summary(fun = mean, geom = "point", colour = cs_ink[["primary"]], size = 3.2, shape = 18) +
  labs(title = "Conference strength, best twelve by average rating",
       subtitle = "Each dot is a team; the diamond is the conference average", x = "Rating", y = NULL,
       caption = sprintf("Teams with %d+ D1 games before %s. ESPN via hoopR.", min_games, asof)) +
  theme_cs()
save_fig(p2, file.path(fig_dir, sprintf("conferences_%s.png", asof)), width = 8, height = 5)

lines <- c(
  sprintf("# State of the season: %s, week of %s", label, format(asof, "%B %-d, %Y")),
  "",
  sprintf("Public data only (ESPN via hoopR): %s games before %s, %s of them between D1 teams. Ratings are points better than an average D1 team on a neutral floor, from a ridge least-squares fit of every D1 margin so far. Home-court advantage this season: **%s points**; a typical game's margin misses the ratings by %s points (residual SD).",
          format(nrow(games), big.mark = ","), format(asof, "%b %-d"), format(nrow(d1g), big.mark = ","),
          fmt(fit_now$hca), fmt(sigma)),
  "",
  "## Top 25",
  "",
  "Week = change in rating points (and in rank) since a week ago. SOS = average rating of D1 opponents played.",
  "",
  md_table(top25),
  "",
  "## Movers this week",
  "",
  sprintf("![Biggest rating moves](figures/movers_%s.png)", asof),
  "",
  md_table(bind_rows(up, down) %>% transmute(Team = team, Conf = conf, `A week ago` = fmt(rating_prev), Now = fmt(rating), Change = signed(change))),
  "",
  "## Efficiency and pace",
  "",
  "Points per 100 possessions, not adjusted for opponents (the rating is). Tempo is possessions per game.",
  "",
  md_table(eligible %>% arrange(desc(off)) %>% head(5) %>% transmute(`Best offense` = team, `Pts/100` = fmt(off))),
  "",
  md_table(eligible %>% arrange(def) %>% head(5) %>% transmute(`Best defense` = team, `Allowed/100` = fmt(def))),
  "",
  md_table(bind_rows(eligible %>% arrange(desc(tempo)) %>% head(3) %>% mutate(kind = "Fastest"),
                     eligible %>% arrange(tempo) %>% head(3) %>% mutate(kind = "Slowest")) %>%
             transmute(Pace = kind, Team = team, Tempo = fmt(tempo), `3PA share` = paste0(fmt(100 * three_rate, 0), "%"))),
  "",
  "## Luck",
  "",
  "Wins minus the wins the ratings expected from each game. Close-game records (4 points or fewer, or overtime) drive most of it, and they rarely persist (study 08).",
  "",
  md_table(bind_rows(luckiest %>% mutate(k = "Luckiest"), unluckiest %>% mutate(k = "Least lucky")) %>%
             transmute(` ` = k, Team = team, Record = record, `Wins vs expected` = signed(luck), `Close games` = sprintf("%d-%d", close_w, close_l))),
  "",
  "## Conference strength",
  "",
  sprintf("![Conference strength](figures/conferences_%s.png)", asof),
  "",
  md_table(head(conf_tbl, 12) %>% transmute(Conference = conf, Teams = teams, `Avg rating` = fmt(mean_rating), Best = best, `Top 50` = top50)),
  "",
  "## Method",
  "",
  sprintf("- Ratings: ridge least squares, margin = home rating - away rating + home-court advantage (0 at neutral sites), D1 vs D1 only, penalty 1 on team ratings; teams with fewer than %d D1 games are left out of the tables. Early in the season the ratings rest on few games and move a lot.", min_games),
  "- Expected wins: each game's win probability is pnorm(expected margin / residual SD).",
  "- Code: `studies/13-weekly-state-of-the-season/report.R` in this repo. The same script runs on the live season every Monday."
)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
writeLines(lines, out)

if (is_sample) {
  res <- file.path(study_dir, "results")
  dir.create(res, showWarnings = FALSE)
  readr::write_csv(teams %>% select(rank, team, conf, record, rating, rating_prev, change, sos, luck, close_w, close_l,
                                    off, def, tempo, three_rate, d1_games), file.path(res, sprintf("teams_%s.csv", asof)))
  readr::write_csv(conf_tbl, file.path(res, sprintf("conferences_%s.csv", asof)))
}
cat("wrote", out, "\n")
