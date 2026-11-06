# Study 05: does playing yesterday cost a team in a conference tournament?
# Public replication, 2008-09 to 2025-26: ratings fit on games before each game day (no look-ahead), the residual
# (actual home margin minus forecast) regressed on who played yesterday. Compared with the private KenPom-based
# test (results/private_benchmark.csv, aggregates written by private_benchmark.py).
#   Rscript studies/05-rest-as-a-natural-experiment/analysis.R      (from the repo root)
source("R/data.R"); source("R/ratings.R"); source("R/theme.R")
suppressPackageStartupMessages({ library(tidyr); library(readr) })
set.seed(20261105)
dir_s <- "studies/05-rest-as-a-natural-experiment"
fig <- function(name) file.path(dir_s, "figures", name)
res <- function(name) file.path(dir_s, "results", name)
seasons <- 2009:2026
season_label <- function(s) sprintf("%d-%02d", s - 1, s %% 100)

games <- cbb_games(seasons)

# Conference-tournament games. The base rule is ESPN's tournament_id on a regular-season conference game from
# Feb 15 on. ESPN leaves tournament_id empty for most of 2008-09 and 2020-21 and part of 2021-22, but the game notes
# still name the event ("Big Ten Tournament - Quarterfinal"), so the primary rule also accepts those notes. The
# strict rule is kept as a check.
late <- games$season_type == 2 & games$conf_game == 1 & games$date >= as.Date(paste0(games$season, "-02-15"))
by_note <- grepl("tournament|championship", games$notes, ignore.case = TRUE)
games <- games %>% mutate(ct_strict = late & !is.na(tournament_id), ct = late & (!is.na(tournament_id) | by_note))
ct <- games %>% filter(ct)

# Rest from the schedule: every completed game that season, D1 or not.
sched <- bind_rows(games %>% select(season, date, team_id = home_id), games %>% select(season, date, team_id = away_id)) %>%
  distinct()
rest_for <- function(side) {
  ct %>% select(game_id, season, date, team_id = all_of(paste0(side, "_id"))) %>%
    left_join(sched %>% rename(prev = date), by = c("season", "team_id"), relationship = "many-to-many") %>%
    mutate(gap = as.integer(date - prev)) %>%
    group_by(game_id) %>%
    summarise(b2b = as.integer(any(gap == 1, na.rm = TRUE)), in4 = sum(gap >= 1 & gap <= 4, na.rm = TRUE), .groups = "drop") %>%
    rename_with(~ paste0(side, "_", .x), -game_id)
}
ct <- ct %>% left_join(rest_for("home"), by = "game_id") %>% left_join(rest_for("away"), by = "game_id")

# Ratings as of each game day: one ridge fit per (season, date) on that season's games before the date.
fits <- ct %>% distinct(season, date) %>% arrange(season, date)
season_games <- split(games, games$season)
t0 <- Sys.time()
fits$fit <- lapply(seq_len(nrow(fits)), function(i) fit_ratings(season_games[[as.character(fits$season[i])]], before = fits$date[i]))
cat(sprintf("%d rating fits in %.0f s\n", nrow(fits), as.numeric(Sys.time() - t0, units = "secs")))

pred_rows <- lapply(seq_len(nrow(fits)), function(i) {
  f <- fits$fit[[i]]
  x <- ct %>% filter(season == fits$season[i], date == fits$date[i])
  r <- setNames(f$ratings$rating, f$ratings$team_id)
  n <- setNames(f$ratings$games, f$ratings$team_id)
  x %>% mutate(pred = predict_margin(f, home_id, away_id, neutral),
               home_rating = unname(r[home_id]), away_rating = unname(r[away_id]),
               min_games = pmin(unname(n[home_id]), unname(n[away_id])), fit_sigma = f$sigma, fit_hca = f$hca)
})
d_all <- bind_rows(pred_rows)
d <- d_all %>%
  filter(!is.na(pred), min_games >= 10) %>%
  mutate(resid = margin - pred, home_win = as.integer(margin > 0),
         b2b_diff = away_b2b - home_b2b,                       # +1 = only the away team played yesterday
         fat_diff = as.integer(away_in4 >= 2) - as.integer(home_in4 >= 2),
         tournament = paste(season, coalesce(tournament_id, sub(" - .*", "", toupper(notes)))))
cat(sprintf("conference-tournament games: %d (strict rule %d); rated: %d\n", nrow(ct), sum(ct$ct_strict), nrow(d)))

ols <- function(y, X) {
  X <- cbind(1, as.matrix(X))
  b <- solve(crossprod(X), crossprod(X, y))
  r <- y - X %*% b
  v <- solve(crossprod(X)) * sum(r^2) / (length(y) - ncol(X))
  list(b = as.numeric(b), se = sqrt(diag(v)))
}
# Cost of being the tired team, in points: the coefficient on (away tired - home tired) in resid ~ 1 + diff.
# Positive = the tired team fell short of its forecast. Also the plain mean residual from the tired team's side.
cost <- function(x, col = "b2b_diff") {
  o <- ols(x$resid, x[[col]])
  one <- x[x[[col]] != 0, ]
  r <- ifelse(one[[col]] > 0, -one$resid, one$resid)
  tibble(n_games = nrow(x), n_mismatch = nrow(one), cost_points = o$b[2], cost_se = o$se[2],
         tired_side_mean = mean(r), tired_side_se = sd(r) / sqrt(nrow(one)))
}

# 1. Effect by season and pooled, both definitions of "tired".
by_season <- bind_rows(lapply(c("b2b_diff", "fat_diff"), function(col) {
  bind_rows(d %>% group_by(season) %>% group_modify(~ cost(.x, col)) %>% ungroup() %>% mutate(season = as.character(season)),
            cost(d, col) %>% mutate(season = "all")) %>%
    mutate(definition = ifelse(col == "b2b_diff", "played_yesterday", "two_plus_in_4_days"))
})) %>% mutate(source = "public_ridge", .before = 1)

# Cluster bootstrap by tournament (games in one bracket share a schedule and a site).
boot_cost <- function(x, col = "b2b_diff", B = 1000) {
  ids <- unique(x$tournament)
  idx <- split(seq_len(nrow(x)), x$tournament)
  replicate(B, {
    take <- unlist(idx[sample(ids, replace = TRUE)], use.names = FALSE)
    ols(x$resid[take], x[[col]][take])$b[2]
  })
}
bt <- boot_cost(d)
pooled <- by_season %>% filter(definition == "played_yesterday", season == "all")
cat(sprintf("played yesterday, all seasons: %.2f points (SE %.2f; cluster bootstrap 95%% CI %.2f to %.2f), %d of %d games\n",
            pooled$cost_points, pooled$cost_se, quantile(bt, .025), quantile(bt, .975), pooled$n_mismatch, pooled$n_games))

# 2. Robustness: alternative samples and controls, all for the played-yesterday definition.
spec <- function(label, x, controls = NULL) {
  X <- x %>% select(b2b_diff, all_of(controls))
  o <- ols(x$resid, X)
  tibble(check = label, n_games = nrow(x), n_mismatch = sum(x$b2b_diff != 0), cost_points = o$b[2], cost_se = o$se[2])
}
fav_tired <- with(d, (b2b_diff > 0 & pred < 0) | (b2b_diff < 0 & pred > 0))   # tired team was the forecast favorite
strict_ids <- ct$game_id[ct$ct_strict]
robust <- bind_rows(
  spec("All games (primary)", d),
  spec("Strict rule: ESPN tournament id only", d %>% filter(game_id %in% strict_ids)),
  spec("Drop 2019-20 and 2020-21 (COVID seasons)", d %>% filter(!season %in% c(2020, 2021))),
  spec("Neutral-site games only", d %>% filter(neutral == 1)),
  spec("Campus-site games only", d %>% filter(neutral == 0)),
  spec("Control for forecast margin and 2+ games in 4 days", d, c("pred", "fat_diff")),
  spec("Tired team was the forecast favorite", d %>% filter(b2b_diff == 0 | fav_tired)),
  spec("Tired team was the forecast underdog", d %>% filter(b2b_diff == 0 | !fav_tired)),
  spec("2008-09 to 2013-14", d %>% filter(season <= 2014)),
  spec("2014-15 to 2019-20", d %>% filter(season >= 2015, season <= 2020)),
  spec("2020-21 to 2025-26", d %>% filter(season >= 2021)),
  spec("Same seasons as the private test (2022-23 to 2025-26)", d %>% filter(season >= 2023))
) %>% mutate(ci_low = cost_points - 1.96 * cost_se, ci_high = cost_points + 1.96 * cost_se)
robust <- bind_rows(robust[1, ] %>% mutate(check = "All games, cluster bootstrap by tournament",
                                           ci_low = quantile(bt, .025), ci_high = quantile(bt, .975), cost_se = sd(bt)),
                    robust)
print(robust, n = 30, width = 200)

# Who is rested? The balance check behind the natural-experiment framing.
balance <- d %>% filter(b2b_diff != 0) %>%
  mutate(tired_rating = ifelse(b2b_diff > 0, away_rating, home_rating),
         rested_rating = ifelse(b2b_diff > 0, home_rating, away_rating),
         gap = rested_rating - tired_rating, tired_is_home_listed = b2b_diff < 0)
calib <- ols(d$resid, d$pred)
cat(sprintf("rested team rated %.2f points better on average (SD %.2f, n %d); rested team better-rated in %.0f%%\n",
            mean(balance$gap), sd(balance$gap), nrow(balance), 100 * mean(balance$gap > 0)))
cat(sprintf("forecast slope check: residual on forecast margin %.3f (SE %.3f)\n", calib$b[2], calib$se[2]))

# 3. Leave one season out: fit the points on the other seasons, score the held-out one. sigma = residual SD in the
# other seasons, so the probabilities are out of sample too.
loso <- bind_rows(lapply(seasons, function(s) {
  tr <- d %>% filter(season != s); te <- d %>% filter(season == s)
  if (nrow(te) == 0) return(NULL)
  k <- ols(tr$resid, tr$b2b_diff)$b[2]
  sig <- sd(tr$resid)
  p0 <- pnorm(te$pred / sig); p1 <- pnorm((te$pred + k * te$b2b_diff) / sig)
  mm <- te$b2b_diff != 0
  tibble(season = s, n_games = nrow(te), n_mismatch = sum(mm), fitted_points = k, sigma = sig,
         brier_base = mean((p0 - te$home_win)^2), brier_rest = mean((p1 - te$home_win)^2),
         brier_base_mismatch = mean((p0[mm] - te$home_win[mm])^2), brier_rest_mismatch = mean((p1[mm] - te$home_win[mm])^2),
         mae_base = mean(abs(te$margin - te$pred)), mae_rest = mean(abs(te$margin - te$pred - k * te$b2b_diff)))
}))
loso_all <- loso %>% summarise(seasons_better = sum(brier_rest < brier_base), n_seasons = n(),
                               across(c(brier_base, brier_rest, mae_base, mae_rest), ~ weighted.mean(.x, n_games)),
                               across(c(brier_base_mismatch, brier_rest_mismatch), ~ weighted.mean(.x, n_mismatch)),
                               n_games = sum(n_games), n_mismatch = sum(n_mismatch))
print(loso, width = 200); print(loso_all, width = 200)

# Brier gain with a cluster bootstrap (held-out probabilities fixed, tournaments resampled).
d_loso <- bind_rows(lapply(seasons, function(s) {
  tr <- d %>% filter(season != s); te <- d %>% filter(season == s)
  k <- ols(tr$resid, tr$b2b_diff)$b[2]; sig <- sd(tr$resid)
  te %>% mutate(gain = (pnorm(pred / sig) - home_win)^2 - (pnorm((pred + k * b2b_diff) / sig) - home_win)^2)
}))
idx <- split(seq_len(nrow(d_loso)), d_loso$tournament)
bg <- replicate(2000, { take <- unlist(idx[sample(names(idx), replace = TRUE)], use.names = FALSE); mean(d_loso$gain[take]) })
loso_all <- loso_all %>% mutate(brier_gain = brier_base - brier_rest, gain_ci_low = quantile(bg, .025), gain_ci_high = quantile(bg, .975))
cat(sprintf("LOSO Brier %.4f -> %.4f, gain %.4f (95%% CI %.4f to %.4f); %d of %d seasons better\n",
            loso_all$brier_base, loso_all$brier_rest, loso_all$brier_gain, loso_all$gain_ci_low, loso_all$gain_ci_high,
            loso_all$seasons_better, loso_all$n_seasons))

# Private benchmark (KenPom snapshots, aggregates only), if present.
priv_path <- res("private_benchmark.csv")
priv <- if (file.exists(priv_path)) read_csv(priv_path, show_col_types = FALSE, col_types = cols(season = col_character())) else NULL

# ---- results --------------------------------------------------------------------------------------------------
write_csv(bind_rows(by_season, if (!is.null(priv)) priv %>% filter(source == "private_kenpom", definition != "loso_brier") %>%
                      select(any_of(names(by_season))) else NULL) %>%
            mutate(ci_low = cost_points - 1.96 * cost_se, ci_high = cost_points + 1.96 * cost_se),
          res("effect_by_season.csv"))
write_csv(robust, res("robustness.csv"))
write_csv(bind_rows(loso %>% mutate(season = as.character(season)), loso_all %>% mutate(season = "all")), res("loso_brier.csv"))
write_csv(tibble(stat = c("games_with_one_team_rested", "mean_rating_gap_rested_minus_tired", "sd_rating_gap",
                          "share_rested_team_better_rated", "share_tired_team_listed_home", "forecast_slope", "forecast_slope_se",
                          "home_listed_intercept"),
                 value = c(nrow(balance), mean(balance$gap), sd(balance$gap), mean(balance$gap > 0),
                           mean(balance$tired_is_home_listed), calib$b[2], calib$se[2], ols(d$resid, d$b2b_diff)$b[1])),
          res("balance.csv"))
write_csv(d %>% count(season, name = "games") %>%
            left_join(ct %>% count(season, name = "identified") %>% left_join(ct %>% filter(ct_strict) %>% count(season, name = "strict_rule"), by = "season"), by = "season") %>%
            left_join(d %>% group_by(season) %>% summarise(one_played_yesterday = sum(b2b_diff != 0), both = sum(home_b2b == 1 & away_b2b == 1)), by = "season"),
          res("sample_by_season.csv"))

# ---- figures --------------------------------------------------------------------------------------------------
# Figure 1: cost by season, public replication vs private benchmark.
f1 <- bind_rows(by_season %>% filter(definition == "played_yesterday") %>% mutate(src = "Public ratings (ESPN results)"),
                if (!is.null(priv)) priv %>% filter(source == "private_kenpom", definition == "played_yesterday") %>%
                  mutate(src = "KenPom snapshots (private)") else NULL) %>%
  mutate(label = ifelse(season == "all", "All seasons", season_label(as.integer(ifelse(season == "all", NA, season)))),
         label = factor(label, levels = rev(c(season_label(seasons), "All seasons"))),
         src = factor(src, levels = c("Public ratings (ESPN results)", "KenPom snapshots (private)")),
         lo = cost_points - 1.96 * cost_se, hi = cost_points + 1.96 * cost_se, pooled = season == "all")
p1 <- ggplot(f1, aes(x = cost_points, y = label, colour = src)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0, orientation = "y", linewidth = 0.8, position = position_dodge(width = 0.6)) +
  geom_point(aes(size = pooled), position = position_dodge(width = 0.6)) +
  scale_size_manual(values = c(`FALSE` = 2, `TRUE` = 3.2), guide = "none") +
  scale_colour_manual(values = unname(cs_pal[c("blue", "orange")])) +
  scale_x_continuous(breaks = seq(-8, 10, 2)) +
  labs(title = "Playing yesterday costs a team about 1.5 to 2 points; public and private ratings agree",
       subtitle = "Points the team that played yesterday fell short of its forecast, vs a rested opponent (95% CI)",
       x = "Cost of playing yesterday (points; right of 0 = the tired team underperformed)", y = NULL,
       caption = sprintf("Conference-tournament games, %s to %s. Public: ridge ratings fit before each game day; %s games,\n%s with exactly one team on a back-to-back. Private: KenPom snapshot of each game day, 2022-23 to 2025-26.",
                         season_label(min(seasons)), season_label(max(seasons)), format(pooled$n_games, big.mark = ","), format(pooled$n_mismatch, big.mark = ","))) +
  theme_cs()
save_fig(p1, fig("01_cost_by_season.png"), width = 8.5, height = 7)

# Figure 2: the two definitions of "tired".
f2 <- bind_rows(by_season %>% filter(season == "all") %>% mutate(src = "Public ratings, 2008-09 to 2025-26"),
                if (!is.null(priv)) priv %>% filter(source == "private_kenpom", season == "all", definition != "loso_brier") %>%
                  mutate(src = "KenPom snapshots, 2022-23 to 2025-26") else NULL) %>%
  mutate(def = factor(ifelse(definition == "played_yesterday", "Played yesterday,\nopponent did not",
                             "2+ games in the prior 4 days,\nopponent fewer (old penalty)"),
                      levels = rev(c("Played yesterday,\nopponent did not", "2+ games in the prior 4 days,\nopponent fewer (old penalty)"))),
         src = factor(src, levels = c("Public ratings, 2008-09 to 2025-26", "KenPom snapshots, 2022-23 to 2025-26")),
         lo = cost_points - 1.96 * cost_se, hi = cost_points + 1.96 * cost_se,
         txt = sprintf("%+.2f (n %d)", cost_points, n_mismatch))
p2 <- ggplot(f2, aes(x = cost_points, y = def, colour = src)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0, orientation = "y", linewidth = 0.9, position = position_dodge(width = 0.5)) +
  geom_point(size = 3, position = position_dodge(width = 0.5)) +
  geom_text(aes(x = hi, label = txt), hjust = -0.15, size = 3.3, show.legend = FALSE, position = position_dodge(width = 0.5)) +
  scale_colour_manual(values = unname(cs_pal[c("blue", "orange")])) +
  scale_x_continuous(limits = c(-4, 5.5), breaks = seq(-4, 4, 2)) +
  labs(title = "Only \"played yesterday\" shows a cost; the old 2-in-4-days rule does not",
       subtitle = "Cost in points for the tired team, by definition of tired (95% CI; n = games with exactly one tired team)",
       x = "Cost (points; right of 0 = the tired team underperformed)", y = NULL,
       caption = "Each estimate is the coefficient on (away tired - home tired) in a regression of the forecast residual, with an intercept.") +
  theme_cs()
save_fig(p2, fig("02_definitions.png"), width = 8.5, height = 4.2)

# Figure 3: robustness.
f3 <- robust %>% mutate(check = factor(check, levels = rev(check)), primary = grepl("primary|bootstrap", check))
p3 <- ggplot(f3, aes(x = cost_points, y = check)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_vline(xintercept = pooled$cost_points, colour = cs_ink[["grid"]], linewidth = 0.6, linetype = "dashed") +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high), width = 0, orientation = "y", linewidth = 0.8, colour = cs_pal[["blue"]]) +
  geom_point(size = 2.4, colour = cs_pal[["blue"]]) +
  geom_text(aes(x = ci_high, label = sprintf("%.2f  (n %d)", cost_points, n_mismatch)), hjust = -0.12, size = 3.1,
            colour = cs_ink[["secondary"]]) +
  scale_x_continuous(limits = c(-3.5, 6.8), breaks = seq(-3, 5, 1)) +
  labs(title = "Every cut of the public data points the same way",
       subtitle = "Cost of playing yesterday (points, 95% CI) under alternative samples and controls",
       x = "Cost (points)", y = NULL,
       caption = "Public ridge ratings fit before each game day. n = games with exactly one team on a back-to-back. Dashed line: primary estimate.") +
  theme_cs()
save_fig(p3, fig("03_robustness.png"), width = 9, height = 6)

# Figure 4: leave-one-season-out Brier change.
f4 <- loso %>% mutate(gain = 1000 * (brier_base - brier_rest), label = factor(season_label(season), levels = season_label(seasons)))
p4 <- ggplot(f4, aes(x = label, y = gain)) +
  geom_hline(yintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_col(fill = cs_pal[["blue"]], width = 0.7) +
  labs(title = sprintf("The adjustment helps in %d of %d held-out seasons, by a small margin", loso_all$seasons_better, loso_all$n_seasons),
       subtitle = "Brier score improvement x 1,000 when the back-to-back adjustment (fit on the other seasons) is added",
       x = NULL, y = "Brier improvement x 1,000",
       caption = sprintf("All conference-tournament games in the held-out season. Pooled: %.4f to %.4f (gain 95%% CI %.4f to %.4f, cluster bootstrap).",
                         loso_all$brier_base, loso_all$brier_rest, loso_all$gain_ci_low, loso_all$gain_ci_high)) +
  theme_cs() + theme(axis.text.x = element_text(angle = 45, hjust = 1))
save_fig(p4, fig("04_loso_brier.png"), width = 8.5, height = 4.8)
cat("done\n")
