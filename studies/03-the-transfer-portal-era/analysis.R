# Study 03: in the transfer-portal era, how much of a team carries over from one season to the next?
#   Rscript studies/03-the-transfer-portal-era/analysis.R      (from the repo root; public ESPN data via hoopR)
# Seasons are named by their ending year (2026 = 2025-26). Writes figures/*.png and results/*.csv.
source("R/data.R"); source("R/ratings.R"); source("R/theme.R")
suppressPackageStartupMessages(library(tidyr))
set.seed(2027)
dir <- file.path("studies", "03-the-transfer-portal-era")
fig <- function(name) file.path(dir, "figures", name)
res <- function(df, name) { dir.create(file.path(dir, "results"), FALSE, TRUE); readr::write_csv(df, file.path(dir, "results", name)); invisible(df) }
slab <- function(s) sprintf("%d-%02d", s - 1, s %% 100)
B <- 2000                        # bootstrap replicates (teams resampled as clusters)
seasons <- 2010:2026
# Fixed before looking at outcomes. Eras by target season: pre-portal through 2018-19; transition 2019-20 and
# 2020-21 (portal open, most transfers still sat out, COVID season); free transfer from 2021-22 (one-time exception).
era_of <- function(s) factor(ifelse(s <= 2019, "Pre-portal", ifelse(s <= 2021, "Transition", "Free transfer")),
                             levels = c("Pre-portal", "Transition", "Free transfer"))
COVERAGE_MIN <- 0.8              # team-seasons with player box scores for < 80% of games are dropped

g <- cbb_games(seasons)
pb <- cbb_player_box(seasons)
teams <- bind_rows(g %>% transmute(season, team_id = home_id, team = home_name, d1 = home_d1),
                   g %>% transmute(season, team_id = away_id, team = away_name, d1 = away_d1)) %>%
  distinct(season, team_id, .keep_all = TRUE)

# ---- 1. Team ratings per season: ridge fit on that season's D1 regular season (incl. conference tournaments) ----
rat <- bind_rows(lapply(seasons, function(s) {
  f <- fit_ratings(g %>% filter(season == s, season_type == 2))
  f$ratings %>% transmute(season = s, team_id, rating, n_games = games)
}))

# Split-half reliability of a season rating: random halves of the games, Spearman-Brown corrected.
split_half <- function(s, reps = 10) {
  gs <- g %>% filter(season == s, season_type == 2) %>% d1_only()
  mean(replicate(reps, {
    h <- sample(rep(1:2, length.out = nrow(gs)))
    a <- fit_ratings(gs[h == 1, ])$ratings; b <- fit_ratings(gs[h == 2, ])$ratings
    r <- inner_join(a, b, by = "team_id") %>% with(cor(rating.x, rating.y))
    2 * r / (1 + r)
  }))
}
reliab <- tibble(season = seasons, reliability = sapply(seasons, split_half))

# ---- 2. Player minutes by team-season, coverage check ----
d1set <- teams %>% filter(d1) %>% select(season, team_id)
tg <- bind_rows(g %>% filter(home_d1) %>% transmute(season, game_id, team_id = home_id, ot = ot_periods),
                g %>% filter(away_d1) %>% transmute(season, game_id, team_id = away_id, ot = ot_periods))
pbt <- pb %>% group_by(season, game_id, team_id) %>% summarise(mins = sum(minutes), .groups = "drop")
cov_tg <- tg %>% left_join(pbt, by = c("season", "game_id", "team_id"))
coverage <- cov_tg %>% group_by(season, team_id) %>%
  summarise(games = n(), with_box = sum(!is.na(mins)), .groups = "drop") %>% mutate(coverage = with_box / games)
bad_ts <- coverage %>% filter(coverage < COVERAGE_MIN) %>% select(season, team_id)
quality <- cov_tg %>% group_by(season) %>%
  summarise(team_games = n(), share_with_box = mean(!is.na(mins)),
            share_minutes_within_5 = mean(abs(mins - 200 - 25 * ot) <= 5, na.rm = TRUE), .groups = "drop") %>%
  left_join(coverage %>% group_by(season) %>% summarise(d1_teams = n(), teams_below_80pct = sum(coverage < COVERAGE_MIN),
                                                        teams_below_90pct = sum(coverage < 0.9)), by = "season")

ps <- pb %>% semi_join(d1set, by = c("season", "team_id")) %>%
  group_by(season, team_id, athlete_id) %>% summarise(min = sum(minutes), gp = n(), first_date = min(date), .groups = "drop") %>%
  group_by(season, team_id) %>% mutate(share = min / sum(min)) %>% ungroup()     # share of the team's minutes
prim <- ps %>% group_by(season, athlete_id) %>% arrange(desc(min), .by_group = TRUE) %>%
  summarise(team1 = first(team_id), share1 = first(share), n_teams = n(), .groups = "drop")

# ---- 3. Where each season's minutes came from (target seasons 2012+, two prior seasons needed) ----
# returning: played for this team last season. D1 transfer: last season for another D1 team (immediate), or no D1
# minutes last season but another D1 team the season before (sat out a year, the pre-2021 norm). Back after a
# season out: same team two seasons ago, none last season (injury, redshirt). New to D1: no D1 minutes in either
# prior season (freshmen, redshirt freshmen, junior-college, lower-division and international arrivals).
cls <- ps %>% filter(season >= 2012) %>%
  left_join(ps %>% transmute(season = season + 1, team_id, athlete_id, on_l1 = TRUE), by = c("season", "team_id", "athlete_id")) %>%
  left_join(ps %>% transmute(season = season + 2, team_id, athlete_id, on_l2 = TRUE), by = c("season", "team_id", "athlete_id")) %>%
  left_join(prim %>% transmute(season = season + 1, athlete_id, old1 = team1, oshare1 = share1), by = c("season", "athlete_id")) %>%
  left_join(prim %>% transmute(season = season + 2, athlete_id, old2 = team1, oshare2 = share1), by = c("season", "athlete_id")) %>%
  mutate(origin = case_when(coalesce(on_l1, FALSE) ~ "Returning",
                            !is.na(old1) ~ "D1 transfer, immediate",
                            coalesce(on_l2, FALSE) ~ "Back after a season out",
                            !is.na(old2) ~ "D1 transfer, after a season out",
                            TRUE ~ "New to D1"))
origin_share <- cls %>% group_by(season, origin) %>% summarise(players = n(), minutes = sum(min), .groups = "drop") %>%
  group_by(season) %>% mutate(minutes_share = minutes / sum(minutes)) %>% ungroup() %>%
  mutate(season_label = slab(season)) %>% arrange(season, origin)
res(origin_share, "minutes_by_origin.csv")

transfers <- origin_share %>% filter(grepl("transfer", origin)) %>%
  select(season, season_label, origin, players, minutes_share) %>% arrange(season, origin)
res(transfers, "transfers_per_season.csv")

# ID check: new-to-D1 players whose exact name matches a different athlete_id on a D1 team in the two prior seasons.
# Most are namesakes; the share is an upper bound on minutes misfiled by an ESPN id change.
nm <- pb %>% distinct(season, athlete_id, athlete_name)
newp <- cls %>% filter(origin == "New to D1") %>% left_join(nm, by = c("season", "athlete_id"))
cand <- bind_rows(lapply(1:2, function(l) newp %>%
  inner_join(nm %>% transmute(season = season + l, athlete_name, pid = athlete_id), by = c("season", "athlete_name"),
             relationship = "many-to-many") %>% filter(pid != athlete_id))) %>% distinct(season, team_id, athlete_id, .keep_all = TRUE)
id_check <- newp %>% group_by(season) %>% summarise(new_players = n(), new_minutes = sum(min)) %>%
  left_join(cand %>% group_by(season) %>% summarise(name_matches = n(), match_minutes = sum(min)), by = "season") %>%
  mutate(share_of_new_minutes = match_minutes / new_minutes,
         share_of_all_minutes = match_minutes / (origin_share %>% group_by(season) %>% summarise(m = sum(minutes)) %>% pull(m)))
spot <- c("Anthony Gill", "Kyle Wiltjer", "Damion Lee", "Grant Sherfield", "Tyler Kolek", "Oumar Ballo", "Johni Broome",
          "Mark Sears", "Dalton Knecht", "Max Abmas", "Hunter Dickinson", "Kerr Kriisa", "Graham Ike", "Walter Clayton Jr.",
          "PJ Haggerty", "P.J. Haggerty", "Yaxel Lendeborg", "Donovan Dent", "Robert Wright III", "Zach Edey")
spot_check <- pb %>% filter(athlete_name %in% spot) %>% group_by(athlete_id, season, team_id) %>%
  summarise(name_in_box = first(athlete_name), games = n(), minutes = sum(minutes), .groups = "drop") %>%
  left_join(teams %>% select(season, team_id, team), by = c("season", "team_id")) %>%
  group_by(athlete_id) %>% mutate(player = first(sub("^P\\.J\\.", "PJ", name_in_box)), ids_for_name = n_distinct(athlete_id)) %>% ungroup() %>%
  mutate(season_label = slab(season)) %>% select(player, athlete_id, season_label, team, name_in_box, games, minutes) %>% arrange(player, season_label)
res(spot_check, "athlete_id_spot_check.csv")
res(quality %>% left_join(id_check %>% select(season, name_matches, share_of_new_minutes, share_of_all_minutes), by = "season") %>%
      mutate(season_label = slab(season)) %>% relocate(season_label, .after = season), "data_quality.csv")

# ---- 4. Team-season features (knowable before season s once rosters are set) ----
r_prev <- rat %>% transmute(season = season + 1, team_id, prev = rating)
r_prev2 <- rat %>% transmute(season = season + 2, team_id, prev2 = rating)
roster_feats <- function(cls_in, ps_prev) {
  # ret: share of last season's minutes (on this team) played by players who are on the team this season
  back <- cls_in %>% distinct(season, team_id, athlete_id)
  ret <- ps_prev %>% filter(season >= 2011, season <= 2025) %>%
    left_join(back %>% transmute(season = season - 1, team_id, athlete_id, back = TRUE), by = c("season", "team_id", "athlete_id")) %>%
    group_by(season, team_id) %>% summarise(ret = sum(share[coalesce(back, FALSE)]), .groups = "drop") %>% mutate(season = season + 1)
  # incoming D1 transfers: their share of their old team's minutes, and that share times the old team's rating
  tin <- cls_in %>% filter(grepl("transfer", origin)) %>%
    mutate(imm = origin == "D1 transfer, immediate", old = ifelse(imm, old1, old2), oshare = ifelse(imm, oshare1, oshare2),
           oseason = ifelse(imm, season - 1L, season - 2L)) %>%
    left_join(rat %>% transmute(oseason = season, old = team_id, orating = rating), by = c("oseason", "old")) %>%
    group_by(season, team_id) %>% summarise(tin_min = sum(oshare), tin_q = sum(oshare * coalesce(orating, 0)), .groups = "drop")
  # outgoing: share of last season's minutes played by players now on another D1 team
  now <- cls_in %>% transmute(season = season - 1, athlete_id, nteam = team_id) %>% distinct()
  tout <- ps_prev %>% filter(season >= 2011) %>% inner_join(now, by = c("season", "athlete_id"), relationship = "many-to-many") %>%
    group_by(season, team_id, athlete_id, share) %>% summarise(stay = any(nteam == team_id), .groups = "drop") %>% filter(!stay) %>%
    group_by(season, team_id) %>% summarise(tout_min = sum(share), .groups = "drop") %>% mutate(season = season + 1)
  list(ret = ret, tin = tin, tout = tout)
}
build_tm <- function(f) {
  rat %>% inner_join(r_prev, by = c("season", "team_id")) %>% inner_join(r_prev2, by = c("season", "team_id")) %>%
    inner_join(f$ret, by = c("season", "team_id")) %>% left_join(f$tin, by = c("season", "team_id")) %>%
    left_join(f$tout, by = c("season", "team_id")) %>%
    mutate(across(c(tin_min, tin_q, tout_min), ~ coalesce(., 0)), era = era_of(season)) %>%
    filter(season >= 2012) %>%
    anti_join(bad_ts, by = c("season", "team_id")) %>% anti_join(bad_ts %>% mutate(season = season + 1L), by = c("season", "team_id"))
}
tm <- build_tm(roster_feats(cls, ps))
# Robustness: roster = players who appear in one of the team's first five games (closer to a preseason roster;
# drops midseason arrivals and players who only return late from injury).
cut5 <- ps %>% distinct(season, team_id) %>%
  left_join(pb %>% distinct(season, team_id, date) %>% group_by(season, team_id) %>% arrange(date, .by_group = TRUE) %>%
              summarise(cut5 = date[min(5, n())], .groups = "drop"), by = c("season", "team_id"))
tm_early <- build_tm(roster_feats(cls %>% left_join(cut5, by = c("season", "team_id")) %>% filter(first_date <= cut5), ps))

team_continuity <- tm %>% group_by(season) %>%
  summarise(teams = n(), median_returning_share = median(ret), p10_returning_share = quantile(ret, 0.1),
            p90_returning_share = quantile(ret, 0.9), mean_transfer_in_share = mean(tin_min), mean_transfer_out_share = mean(tout_min),
            .groups = "drop") %>% mutate(season_label = slab(season)) %>% relocate(season_label, .after = season)
res(team_continuity, "team_continuity.csv")

# ---- 5. Persistence: correlation of a team's rating with its rating the season before ----
pairs <- rat %>% inner_join(r_prev, by = c("season", "team_id")) %>% filter(season >= 2011) %>%
  anti_join(bad_ts, by = c("season", "team_id")) %>% mutate(era = era_of(season))
ids <- sort(unique(pairs$team_id))
wcor <- function(x, y, w) { mx <- sum(w * x) / sum(w); my <- sum(w * y) / sum(w)
  sum(w * (x - mx) * (y - my)) / sqrt(sum(w * (x - mx)^2) * sum(w * (y - my)^2)) }
W <- matrix(rmultinom(B, length(ids), rep(1, length(ids))), nrow = length(ids))    # team weights per replicate
widx <- match(pairs$team_id, ids)
ss <- sort(unique(pairs$season))
boot_r <- sapply(seq_len(B), function(b) { w <- W[widx, b]
  sapply(ss, function(s) { k <- pairs$season == s; wcor(pairs$prev[k], pairs$rating[k], w[k]) }) })
point_r <- sapply(ss, function(s) with(pairs[pairs$season == s, ], cor(prev, rating)))
persist <- tibble(season = ss, season_label = slab(ss), era = era_of(ss), teams = as.integer(table(pairs$season)[as.character(ss)]),
                  r = point_r, r_lo = apply(boot_r, 1, quantile, 0.025), r_hi = apply(boot_r, 1, quantile, 0.975),
                  slope = sapply(ss, function(s) coef(lm(rating ~ prev, pairs[pairs$season == s, ]))[[2]])) %>%
  left_join(reliab, by = "season") %>% left_join(reliab %>% transmute(season = season + 1, rel_prev = reliability), by = "season") %>%
  mutate(r_disattenuated = r / sqrt(reliability * rel_prev), rating_sd = sapply(ss, function(s) sd(rat$rating[rat$season == s]))) %>%
  select(-rel_prev)
res(persist, "persistence_by_season.csv")
era_mean <- function(M, e) colMeans(M[era_of(ss) == e, , drop = FALSE])
era_boot <- sapply(levels(era_of(ss)), function(e) era_mean(boot_r, e))
era_point <- sapply(levels(era_of(ss)), function(e) mean(point_r[era_of(ss) == e]))
diff_boot <- era_boot[, "Free transfer"] - era_boot[, "Pre-portal"]
persist_era <- tibble(era = c(levels(era_of(ss)), "Free transfer minus pre-portal"),
                      seasons = c(sapply(levels(era_of(ss)), function(e) paste(slab(range(ss[era_of(ss) == e])), collapse = " to ")), ""),
                      mean_r = c(era_point, era_point[["Free transfer"]] - era_point[["Pre-portal"]]),
                      lo = c(apply(era_boot, 2, quantile, 0.025), quantile(diff_boot, 0.025)),
                      hi = c(apply(era_boot, 2, quantile, 0.975), quantile(diff_boot, 0.975)))
res(persist_era, "persistence_by_era.csv")

# ---- 6. Sorting: do players move between teams of similar strength? ----
# Each incoming D1 transfer: receiving team's rating last season vs the old team's rating in the season he played
# there, weighted by the player's share of the old team's minutes.
moves <- cls %>% filter(grepl("transfer", origin)) %>%
  mutate(imm = origin == "D1 transfer, immediate", old = ifelse(imm, old1, old2), oshare = ifelse(imm, oshare1, oshare2),
         oseason = ifelse(imm, season - 1L, season - 2L)) %>%
  inner_join(rat %>% transmute(oseason = season, old = team_id, old_rating = rating), by = c("oseason", "old")) %>%
  inner_join(r_prev, by = c("season", "team_id")) %>% filter(old != team_id) %>% mutate(era = era_of(season))
mids <- sort(unique(moves$team_id)); mW <- matrix(rmultinom(B, length(mids), rep(1, length(mids))), nrow = length(mids))
midx <- match(moves$team_id, mids); ms <- sort(unique(moves$season))
mboot <- sapply(seq_len(B), function(b) { w <- mW[midx, b] * moves$oshare
  sapply(ms, function(s) { k <- moves$season == s; wcor(moves$prev[k], moves$old_rating[k], w[k]) }) })
sorting <- tibble(season = ms, season_label = slab(ms), era = era_of(ms),
                  transfers = as.integer(table(moves$season)[as.character(ms)]),
                  r = sapply(ms, function(s) { k <- moves$season == s; wcor(moves$prev[k], moves$old_rating[k], moves$oshare[k]) }),
                  r_lo = apply(mboot, 1, quantile, 0.025), r_hi = apply(mboot, 1, quantile, 0.975))
res(sorting, "transfer_sorting.csv")
# By fifth of last season's rating (1 = weakest): where incoming transfers came from, and how many minutes they
# brought (in units of a whole team's minutes), averaged over all team-seasons in the fifth.
tq <- tm %>% group_by(season) %>% mutate(receiving_quintile = ntile(prev, 5)) %>% ungroup()
quint <- moves %>% inner_join(tq %>% select(season, team_id, receiving_quintile), by = c("season", "team_id")) %>%
  group_by(era, receiving_quintile) %>%
  summarise(transfers = n(), mean_old_team_rating = weighted.mean(old_rating, oshare), .groups = "drop") %>%
  left_join(tq %>% group_by(era, receiving_quintile) %>%
              summarise(team_seasons = n(), mean_transfer_in_share = mean(tin_min), .groups = "drop"), by = c("era", "receiving_quintile"))
res(quint, "transfer_sorting_by_quintile.csv")

# ---- 7. Models: rating this season from last season's rating and roster movement ----
forms <- list(
  A_last_season = rating ~ prev,
  B_two_seasons = rating ~ prev + prev2,
  C_plus_continuity = rating ~ prev + prev2 + ret + prev:ret,
  D_plus_transfers = rating ~ prev + prev2 + ret + prev:ret + tin_min + tin_q + tout_min)
cluster_se <- function(m, cl) {     # CR1 cluster-robust SEs (clusters = teams)
  X <- model.matrix(m); e <- resid(m); n <- nrow(X); k <- ncol(X); G <- length(unique(cl))
  XtXi <- solve(crossprod(X)); u <- rowsum(X * e, cl)
  sqrt(diag(G / (G - 1) * (n - 1) / (n - k) * XtXi %*% crossprod(u) %*% XtXi))
}
coefs <- bind_rows(lapply(c(levels(tm$era), "All seasons"), function(e) {
  d <- if (e == "All seasons") tm else tm %>% filter(era == e)
  m <- lm(forms$D_plus_transfers, d); se <- cluster_se(m, d$team_id)
  tibble(era = e, term = names(coef(m)), estimate = coef(m), se = se, lo = coef(m) - 1.96 * se, hi = coef(m) + 1.96 * se,
         team_seasons = nrow(d), r_squared = summary(m)$r.squared)
}))
# Era interaction on the persistence slope, without and with the roster terms
mi0 <- lm(rating ~ prev * era, tm); mi1 <- lm(rating ~ prev * era + prev2 + ret + prev:ret + tin_min + tin_q + tout_min, tm)
era_int <- bind_rows(lapply(list(without_roster_terms = mi0, with_roster_terms = mi1), function(m) {
  se <- cluster_se(m, tm$team_id); k <- grepl("^prev:era", names(coef(m)))
  tibble(term = names(coef(m))[k], estimate = coef(m)[k], se = se[k])
}), .id = "model")
res(bind_rows(coefs, era_int %>% transmute(era = model, term, estimate, se, lo = estimate - 1.96 * se, hi = estimate + 1.96 * se,
                                           team_seasons = nrow(tm), r_squared = NA_real_)), "model_coefficients.csv")

# Rolling-origin holdout: each test season predicted from models fit on all earlier seasons (2011-12 onward).
test_seasons <- 2015:2026
roll <- function(d) bind_rows(lapply(test_seasons, function(s) {
  tr <- d %>% filter(season < s); te <- d %>% filter(season == s)
  out <- te %>% transmute(season, team_id, era, rating, naive_last_season = prev, naive_average = 0)
  for (nm in names(forms)) out[[nm]] <- predict(lm(forms[[nm]], tr), te)
  out
}))
pred <- roll(tm)
pred_early <- roll(tm_early)
mods <- c("naive_average", "naive_last_season", names(forms))
rmse_tab <- function(p, label) {
  long <- p %>% pivot_longer(all_of(mods), names_to = "model", values_to = "pred") %>% mutate(err2 = (rating - pred)^2)
  by_season <- long %>% group_by(season, model) %>% summarise(rmse = sqrt(mean(err2)), teams = n(), .groups = "drop")
  pooled <- long %>% mutate(group = ifelse(season <= 2019, "Test 2014-15 to 2018-19", ifelse(season <= 2021, "Test 2019-20 to 2020-21", "Test 2021-22 to 2025-26"))) %>%
    bind_rows(long %>% mutate(group = "All test seasons")) %>% group_by(group, model) %>%
    summarise(rmse = sqrt(mean(err2)), team_seasons = n(), .groups = "drop")
  list(by_season = by_season %>% mutate(definition = label), pooled = pooled %>% mutate(definition = label))
}
rt <- rmse_tab(pred, "roster = any appearance"); rte <- rmse_tab(pred_early, "roster = played in first five games")
# Paired cluster bootstrap (teams) for the RMSE gain of D over A and over B
gain_boot <- function(p, base, grp) {
  d <- p %>% filter(grp(season)); tid <- sort(unique(d$team_id)); ix <- match(d$team_id, tid)
  eD <- (d$rating - d$D_plus_transfers)^2; eX <- (d$rating - d[[base]])^2
  bt <- replicate(B, { w <- tabulate(sample(length(tid), replace = TRUE), length(tid))[ix]
    sqrt(sum(w * eX) / sum(w)) - sqrt(sum(w * eD) / sum(w)) })
  c(gain = sqrt(mean(eX)) - sqrt(mean(eD)), lo = quantile(bt, 0.025, names = FALSE), hi = quantile(bt, 0.975, names = FALSE), n = nrow(d))
}
grps <- list("All test seasons" = function(s) s > 0, "Test 2014-15 to 2018-19" = function(s) s <= 2019,
             "Test 2021-22 to 2025-26" = function(s) s >= 2022)
gains <- bind_rows(lapply(c("A_last_season", "B_two_seasons"), function(base) bind_rows(lapply(names(grps), function(gn) {
  x <- gain_boot(pred, base, grps[[gn]]); tibble(baseline = base, group = gn, rmse_gain_points = x[["gain"]], lo = x[["lo"]], hi = x[["hi"]], team_seasons = x[["n"]])
}))))
res(bind_rows(rt$by_season, rte$by_season) %>% mutate(season_label = slab(season)), "holdout_rmse_by_season.csv")
res(bind_rows(rt$pooled, rte$pooled), "holdout_rmse_pooled.csv")
res(gains, "holdout_rmse_gain.csv")

# ---- 8. Figures ----
marks <- tibble(x = c(2019.5, 2021.5), lab = c("Portal opens\n(Oct 2018)", "One-time transfer\nexception (2021)"))
xs <- scale_x_continuous(breaks = c(2012, 2015, 2018, 2021, 2024, 2026), labels = slab, expand = expansion(add = c(0.4, 0.4)))
# Portal label sits left of its line, the 2021 rule label right of its line, so the two never collide.
vlines <- function(ytop) list(geom_vline(xintercept = marks$x, linetype = "dashed", colour = cs_ink[["baseline"]], linewidth = 0.5),
                              annotate("text", x = marks$x + c(-0.12, 0.12), y = ytop, label = marks$lab, hjust = c(1, 0), vjust = 1,
                                       size = 3, colour = cs_ink[["secondary"]], lineheight = 0.9))
n_tm <- nrow(tm)

# Fig 1: where the minutes came from
o3 <- origin_share %>% filter(origin != "Back after a season out") %>%
  mutate(grp = case_when(origin == "Returning" ~ "Returning to the same team", grepl("transfer", origin) ~ "D1 transfers", TRUE ~ "New to D1")) %>%
  group_by(season, grp) %>% summarise(share = sum(minutes_share), .groups = "drop") %>%
  mutate(grp = factor(grp, levels = c("Returning to the same team", "D1 transfers", "New to D1")))
lab1 <- o3 %>% filter(season == 2026) %>%
  mutate(label_y = c("Returning to the same team" = 0.335, "D1 transfers" = 0.415, "New to D1" = 0.255)[as.character(grp)],
         label = sprintf("%s\n%.0f%%", c("Returning to the same team" = "Returning", "D1 transfers" = "D1 transfers",
                                          "New to D1" = "New to D1")[as.character(grp)], 100 * share))
p1 <- ggplot(o3, aes(season, share, colour = grp)) + vlines(0.79) +
  geom_line(linewidth = 1) + geom_point(size = 2) +
  geom_text(data = lab1, aes(y = label_y, label = label), hjust = 0, nudge_x = 0.3, size = 3.2, lineheight = 0.9, show.legend = FALSE) +
  scale_colour_manual(values = unname(cs_pal[c("blue", "orange", "aqua")]), guide = "none") +
  scale_y_continuous(labels = scales::percent, limits = c(0, 0.8), expand = expansion(mult = c(0, 0.02))) +
  scale_x_continuous(breaks = c(2012, 2015, 2018, 2021, 2024, 2026), labels = slab, limits = c(2011.6, 2027.9)) +
  labs(title = "Returning players now play a third of D1 minutes, down from two thirds",
       subtitle = "Share of all D1 minutes each season, by where the player was the season before",
       x = NULL, y = "Share of D1 minutes",
       caption = sprintf("Source: ESPN box scores via hoopR; %s player-team-seasons. D1 transfers include players who sat out a year first.\nPlayers back at the same school after a season out (about 1%% of minutes) are omitted here; see results/minutes_by_origin.csv.",
                         format(nrow(cls), big.mark = ","))) +
  theme_cs() + theme(panel.grid.major.x = element_blank())
save_fig(p1, fig("01_minutes_by_origin.png"))

# Fig 2: transfers per season, by path
t2 <- transfers %>% mutate(origin = factor(origin, levels = c("D1 transfer, after a season out", "D1 transfer, immediate"),
                                         labels = c("Sat out a season first", "Played right away")))
tot2 <- t2 %>% group_by(season) %>% summarise(n = sum(players))
p2 <- ggplot(t2, aes(season, players, fill = origin)) + geom_col(width = 0.75) +
  geom_text(data = tot2, aes(season, n, label = scales::comma(n)), inherit.aes = FALSE, vjust = -0.4, size = 2.9, colour = cs_ink[["secondary"]]) +
  geom_vline(xintercept = marks$x, linetype = "dashed", colour = cs_ink[["baseline"]], linewidth = 0.5) +
  annotate("text", x = marks$x + c(-0.12, 0.12), y = 1700, label = marks$lab, hjust = c(1, 0), vjust = 1, size = 3,
           colour = cs_ink[["secondary"]], lineheight = 0.9) +
  scale_fill_manual(values = c("Sat out a season first" = cs_pal[["blue"]], "Played right away" = cs_pal[["orange"]]),
                    breaks = c("Sat out a season first", "Played right away")) +
  scale_y_continuous(labels = scales::comma, limits = c(0, 1720), expand = expansion(mult = c(0, 0))) + xs +
  labs(title = "Six times as many D1-to-D1 transfers played in 2025-26 as in 2011-12",
       subtitle = "Players who appeared for a D1 team after playing for a different D1 team in one of the two prior seasons",
       x = NULL, y = "Transfers who played",
       caption = "Source: ESPN box scores via hoopR. Counts transfers who played at least once for the new team, not portal entries.") +
  theme_cs() + theme(panel.grid.major.x = element_blank())
save_fig(p2, fig("02_transfers_per_season.png"))

# Fig 3: persistence
seg <- persist %>% group_by(era) %>% summarise(x0 = min(season) - 0.4, x1 = max(season) + 0.4, m = mean(r))
p3 <- ggplot(persist, aes(season, r)) + vlines(0.95) +
  geom_segment(data = seg, aes(x = x0, xend = x1, y = m, yend = m), inherit.aes = FALSE, colour = cs_pal[["orange"]], linewidth = 0.9) +
  geom_text(data = seg, aes(x = (x0 + x1) / 2, y = 0.705, label = sprintf("%s\nmean %.2f", era, m)), inherit.aes = FALSE,
            size = 3, colour = cs_ink[["secondary"]], lineheight = 0.9) +
  geom_errorbar(aes(ymin = r_lo, ymax = r_hi), width = 0, colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(size = 2.4, colour = cs_pal[["blue"]]) +
  scale_y_continuous(limits = c(0.68, 0.95), breaks = seq(0.7, 0.95, 0.05)) +
  scale_x_continuous(breaks = c(2011, 2014, 2017, 2020, 2023, 2026), labels = slab, expand = expansion(add = c(0.6, 0.6))) +
  labs(title = "Team strength carried over about as much after the portal as before it",
       subtitle = "Correlation of each D1 team's rating with its rating the season before, with 95% bootstrap intervals",
       x = NULL, y = "Year-to-year correlation",
       caption = sprintf("Source: ESPN results via hoopR. Ridge ratings from each regular season's D1 games; %s team pairs, about 350 a season.\nOrange lines: era means. 2020-21 was the shortened COVID season.",
                         format(nrow(pairs), big.mark = ","))) +
  theme_cs() + theme(panel.grid.major.x = element_blank())
save_fig(p3, fig("03_persistence.png"))

# Fig 4: sorting
p4 <- ggplot(sorting, aes(season, r)) + vlines(0.78) +
  geom_hline(yintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.5) +
  geom_errorbar(aes(ymin = r_lo, ymax = r_hi), width = 0, colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(size = 2.4, colour = cs_pal[["blue"]]) + xs +
  scale_y_continuous(limits = c(-0.05, 0.8), breaks = seq(0, 0.8, 0.2)) +
  labs(title = "Strong teams now restock with players from strong teams",
       subtitle = "Correlation between a team's rating last season and the rating of the teams its incoming transfers left,\nweighted by each transfer's share of the old team's minutes, with 95% bootstrap intervals",
       x = NULL, y = "Correlation",
       caption = sprintf("Source: ESPN box scores and results via hoopR; %s D1-to-D1 transfers who played, 2011-12 to 2025-26,\nwhere both the old and the new team have ratings.",
                         format(nrow(moves), big.mark = ","))) +
  theme_cs() + theme(panel.grid.major.x = element_blank())
save_fig(p4, fig("04_transfer_sorting.png"))

# Fig 5: holdout RMSE by test season for the nested priors
f5 <- rt$by_season %>% filter(model %in% c("B_two_seasons", "C_plus_continuity", "D_plus_transfers")) %>%
  mutate(model = factor(model, levels = c("D_plus_transfers", "C_plus_continuity", "B_two_seasons"),
                        labels = c("+ incoming transfers", "+ returning minutes", "Team history only")))
lab5 <- f5 %>% filter(season == 2026)
p5 <- ggplot(f5, aes(season, rmse, colour = model)) + vlines(6.2) +
  geom_line(linewidth = 1) + geom_point(size = 2.2) +
  geom_text(data = lab5, aes(label = sprintf("%s\n%.2f", model, rmse)), hjust = 0, nudge_x = 0.3, size = 3.1, lineheight = 0.9, show.legend = FALSE) +
  scale_colour_manual(values = c(cs_pal[["blue"]], cs_pal[["orange"]], cs_ink[["muted"]]), guide = "none") +
  scale_y_continuous(limits = c(3.8, 6.2), breaks = seq(4, 6, 0.5)) +
  scale_x_continuous(breaks = c(2015, 2018, 2021, 2024, 2026), labels = slab, limits = c(2014.6, 2028.9)) +
  labs(title = "Returning minutes alone stopped helping; adding transfers fixed the prior",
       subtitle = "Out-of-sample RMSE (points) for each team's season rating, from models fit only on earlier seasons",
       x = NULL, y = "RMSE vs season rating (points)",
       caption = sprintf("Source: ESPN via hoopR. Rolling-origin holdout, %s team-seasons. Team history = ratings one and two seasons back;\nthe orange model adds returning minutes, the blue one also adds incoming and outgoing transfers.\nAll models, including last season's rating alone, are in results/holdout_rmse_pooled.csv.",
                         format(nrow(pred), big.mark = ","))) +
  theme_cs() + theme(panel.grid.major.x = element_blank())
save_fig(p5, fig("05_preseason_prior.png"))

# ---- 9. Console summary ----
cat("\nTeam-seasons modeled:", n_tm, " dropped for coverage:", nrow(bad_ts), "\n")
print(persist_era)
print(rt$pooled %>% pivot_wider(names_from = group, values_from = rmse, id_cols = model))
print(rte$pooled %>% pivot_wider(names_from = group, values_from = rmse, id_cols = model))
print(gains)
print(coefs %>% filter(era == "All seasons") %>% select(term, estimate, se))
print(era_int)
print(sorting %>% select(season, r, r_lo, r_hi))
print(quint)
cat("Correlation of returning share, any appearance vs first five games:", round(cor(tm$ret, tm_early$ret[match(paste(tm$season, tm$team_id), paste(tm_early$season, tm_early$team_id))], use = "complete.obs"), 3), "\n")
