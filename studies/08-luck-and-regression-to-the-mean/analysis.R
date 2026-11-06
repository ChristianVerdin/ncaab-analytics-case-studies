# Study 08: is winning close games a skill?
# Public data only (ESPN via hoopR, cached under data/cache). Run from the repo root:
#   Rscript studies/08-luck-and-regression-to-the-mean/analysis.R
source("R/data.R"); source("R/ratings.R"); source("R/theme.R")
suppressPackageStartupMessages({ library(tidyr); library(readr) })
set.seed(20261105)
t_start <- Sys.time()
study <- "studies/08-luck-and-regression-to-the-mean"
fig <- function(f) file.path(study, "figures", f)
out <- function(df, f) { dir.create(file.path(study, "results"), FALSE, TRUE); write_csv(df, file.path(study, "results", f)); invisible(df) }
B <- 1000
MIN_GAMES <- 8   # per half

# Close-game definitions, fixed before looking at results. Primary: final margin <= 4 or overtime.
defs <- list(primary = list(label = "Margin <= 4 or OT", k = 4, ot_only = FALSE),
             le3 = list(label = "Margin <= 3 or OT", k = 3, ot_only = FALSE),
             ot = list(label = "Overtime only", k = 0, ot_only = TRUE))

# ---------------------------------------------------------------------------------------------------------------
# Expected wins. Normal theory: a team favored by m points (sigma = the fit's residual SD) wins with pnorm(m / sigma).
# Given that a game was close, the expectation is conditional: in regulation the margin landed in [1, k] either
# way, so P(win | close) = P(0.5 < X < k + 0.5) / P(0.5 < |X| < k + 0.5) with X ~ N(m, sigma); overtime starts
# from a tie and lasts 5 of 40 minutes, so P(win | OT) = pnorm(m * sqrt(5/40) / sigma).
# The calibration check below showed both under-predict favorites (residuals are not one normal), so the
# expectations used are logistic fits on z = m / sigma, each fit leaving out the season it is applied to:
#   all games:   logit P(win) = b1 z + b3 z^3
#   close games: logit P(win | close) = c1 z (regulation) + c2 z (overtime), fit per close-game definition.
# Both are odd in z, so the two sides of a game always sum to one. Normal theory is kept as a robustness check.
# ---------------------------------------------------------------------------------------------------------------
p_close_normal <- function(m, sigma, k, ot) {
  if (k == 0) return(pnorm(m * sqrt(5 / 40) / sigma))
  w <- pnorm((k + 0.5 - m) / sigma) - pnorm((0.5 - m) / sigma)
  l <- pnorm((-0.5 - m) / sigma) - pnorm((-k - 0.5 - m) / sigma)
  ifelse(ot, pnorm(m * sqrt(5 / 40) / sigma), w / (w + l))
}
is_close <- function(margin, ot, d) if (d$ot_only) ot else (ot | abs(margin) <= d$k)
loso <- function(tg, rows, formula_rhs) {
  # rows: logical, the games this model applies to. Fit on the favored side's row (same likelihood as both sides).
  out <- rep(NA_real_, nrow(tg))
  for (s in unique(tg$season)) {
    tr <- rows & tg$season != s & tg$pred > 0
    fit <- glm(reformulate(formula_rhs, "win", intercept = FALSE), binomial, data = tg[tr, ])
    ap <- rows & tg$season == s
    out[ap] <- predict(fit, newdata = tg[ap, ], type = "response")
  }
  out
}
add_expectations <- function(tg) {
  tg <- tg %>% mutate(z = pred / sigma, z3 = z^3, z_reg = z * !ot, z_ot = z * ot, p_win_normal = pnorm(z))
  tg$p_win <- loso(tg, rep(TRUE, nrow(tg)), c("z", "z3"))
  for (nm in names(defs)) {
    d <- defs[[nm]]; cl <- is_close(tg$margin, tg$ot, d)
    tg[[paste0("close_", nm)]] <- cl
    tg[[paste0("pc_", nm)]] <- loso(tg, cl, if (d$ot_only) "z_ot" else c("z_reg", "z_ot"))
    tg[[paste0("pcn_", nm)]] <- ifelse(cl, p_close_normal(tg$pred, tg$sigma, d$k, tg$ot), NA)
  }
  tg
}

# One row per team per game, from that team's side, with the predicted margin from a given ratings fit.
team_games <- function(g, fit) {
  m <- predict_margin(fit, g$home_id, g$away_id, g$neutral)
  bind_rows(
    g %>% transmute(season, game_id, date, half, team_id = home_id, opp_id = away_id, margin, ot = ot_periods > 0, pred = m),
    g %>% transmute(season, game_id, date, half, team_id = away_id, opp_id = home_id, margin = -margin, ot = ot_periods > 0, pred = -m)
  ) %>% mutate(win = as.integer(margin > 0), sigma = fit$sigma)
}
summarise_luck <- function(tg) {
  base <- tg %>% group_by(season, team_id, half) %>%
    summarise(games = n(), wins = sum(win), win_pct = mean(win), margin_pg = mean(margin),
              exp_wins = sum(p_win), luck = sum(win) - sum(p_win), luck_normal = sum(win) - sum(p_win_normal), .groups = "drop")
  for (nm in names(defs)) {
    cl <- tg %>% filter(.data[[paste0("close_", nm)]]) %>% mutate(pc = .data[[paste0("pc_", nm)]], pcn = .data[[paste0("pcn_", nm)]]) %>%
      group_by(season, team_id, half) %>%
      summarise(n = n(), w = sum(win), e = sum(pc), en = sum(pcn), v = sum(pc * (1 - pc)), .groups = "drop") %>%
      rename_with(~ paste0("close_", .x, "_", nm), c(n, w, e, en, v))
    base <- base %>% left_join(cl, by = c("season", "team_id", "half")) %>%
      mutate(across(ends_with(paste0("_", nm)), ~ coalesce(.x, 0)))
    base[[paste0("close_luck_", nm)]] <- base[[paste0("close_w_", nm)]] - base[[paste0("close_e_", nm)]]
    base[[paste0("close_luck_normal_", nm)]] <- base[[paste0("close_w_", nm)]] - base[[paste0("close_en_", nm)]]
    base[[paste0("close_pct_", nm)]] <- ifelse(base[[paste0("close_n_", nm)]] > 0, base[[paste0("close_w_", nm)]] / base[[paste0("close_n_", nm)]], NA)
  }
  base
}

# ---------------------------------------------------------------------------------------------------------------
# Data: D1 vs D1 regular season (incl. conference tournaments), 2007-08 to 2025-26. Each season is split at the
# median game date, so a half-season ratings fit uses only that half's games and the two halves are measured
# independently. Most teams land within a game or two of an even split.
# ---------------------------------------------------------------------------------------------------------------
seasons <- 2008:2026
games <- cbb_games(seasons) %>% d1_only() %>% filter(season_type == 2) %>%
  group_by(season) %>% mutate(split_date = median(date), half = ifelse(date < split_date, 1L, 2L)) %>% ungroup()

per_season <- lapply(seasons, function(s) {
  g <- games %>% filter(season == s)
  f1 <- fit_ratings(g %>% filter(half == 1)); f2 <- fit_ratings(g %>% filter(half == 2)); fs <- fit_ratings(g)
  halves <- bind_rows(team_games(g %>% filter(half == 1), f1), team_games(g %>% filter(half == 2), f2))
  full <- team_games(g %>% mutate(half = 0L), fs)
  # forecast of the second half from first-half ratings only (no look-ahead)
  fc <- team_games(g %>% filter(half == 2), f1)
  list(halves = halves, full = full, fc = fc,
       ratings = bind_rows(f1$ratings %>% mutate(half = 1L), f2$ratings %>% mutate(half = 2L), fs$ratings %>% mutate(half = 0L)) %>% mutate(season = s),
       info = tibble(season = s, split_date = g$split_date[1], games = nrow(g), sigma_h1 = f1$sigma, sigma_h2 = f2$sigma, sigma_full = fs$sigma,
                     hca_full = fs$hca))
})
tg_half <- add_expectations(bind_rows(lapply(per_season, `[[`, "halves")))
tg_full <- add_expectations(bind_rows(lapply(per_season, `[[`, "full")))
ratings <- bind_rows(lapply(per_season, `[[`, "ratings")) %>% select(season, team_id, half, rating)
fc <- add_expectations(bind_rows(lapply(per_season, `[[`, "fc")) %>% filter(!is.na(pred))) %>% group_by(season, team_id) %>%
  summarise(h2_forecast_win_pct = mean(p_win), h2_forecast_margin = mean(pred), .groups = "drop")
out(bind_rows(lapply(per_season, `[[`, "info")), "season_splits.csv")

lh <- summarise_luck(tg_half) %>% left_join(ratings, by = c("season", "team_id", "half"))
wide <- lh %>% pivot_wider(id_cols = c(season, team_id), names_from = half, values_from = -c(season, team_id, half), names_glue = "{.value}_h{half}") %>%
  filter(games_h1 >= MIN_GAMES, games_h2 >= MIN_GAMES) %>% left_join(fc, by = c("season", "team_id"))
lf <- summarise_luck(tg_full) %>% left_join(ratings, by = c("season", "team_id", "half")) %>% filter(games >= 2 * MIN_GAMES)

# ---------------------------------------------------------------------------------------------------------------
# Check 1: is the close-game expectation calibrated? Actual vs expected close-game win rate for the favored side,
# by size of the favorite's predicted edge (in-sample season ratings), primary definition.
# ---------------------------------------------------------------------------------------------------------------
calib <- tg_full %>% filter(pred > 0, close_primary) %>%
  mutate(edge = cut(pred, c(0, 2, 4, 6, 9, 13, Inf), labels = c("0-2", "2-4", "4-6", "6-9", "9-13", "13+"), right = FALSE)) %>%
  group_by(edge) %>%
  summarise(close_games = n(), mean_pred_margin = mean(pred), actual_win_pct = mean(win), se = sqrt(mean(win) * (1 - mean(win)) / n()),
            expected_calibrated = mean(pc_primary), expected_normal_theory = mean(pcn_primary), expected_before_game = mean(p_win_normal), .groups = "drop") %>%
  mutate(ci_low = actual_win_pct - 1.96 * se, ci_high = actual_win_pct + 1.96 * se)
calib_all <- tg_full %>% filter(pred > 0) %>%
  mutate(edge = cut(pred, c(0, 2, 4, 7, 10, 14, 20, Inf), right = FALSE)) %>% group_by(edge) %>%
  summarise(games = n(), actual_win_pct = mean(win), expected_calibrated = mean(p_win), expected_normal_theory = mean(p_win_normal), .groups = "drop")
out(calib_all, "all_game_calibration.csv")
out(calib, "close_game_calibration.csv")

# ---------------------------------------------------------------------------------------------------------------
# 2. Persistence: half 1 vs half 2 within a season, and season s vs s + 1. Pearson correlations with 95%
#    bootstrap CIs that resample teams (all of a team's seasons together).
# ---------------------------------------------------------------------------------------------------------------
cor_boot <- function(x, y, cluster, B) {
  ok <- !is.na(x) & !is.na(y); x <- x[ok]; y <- y[ok]; cl <- cluster[ok]
  idx <- split(seq_along(x), cl); ids <- names(idx)
  bt <- replicate(B, { i <- unlist(idx[sample(ids, length(ids), TRUE)], use.names = FALSE); cor(x[i], y[i]) })
  tibble(r = cor(x, y), ci_low = quantile(bt, 0.025, names = FALSE), ci_high = quantile(bt, 0.975, names = FALSE), n = length(x))
}
measures <- tribble(
  ~measure, ~stem, ~kind,
  "Point margin per game", "margin_pg", "skill",
  "Rating (opponent-adjusted margin)", "rating", "skill",
  "Win percentage", "win_pct", "mixed",
  "Wins above expected (all games)", "luck", "luck",
  "Close-game wins above expected", "close_luck_primary", "luck",
  "Close-game win percentage", "close_pct_primary", "luck",
  "Close-game wins above expected (margin <= 3 or OT)", "close_luck_le3", "robustness",
  "Close-game wins above expected (OT only)", "close_luck_ot", "robustness",
  "Close-game win percentage (3+ close games each half)", "close_pct_primary_min3", "robustness",
  "Wins above expected (normal-theory expectation)", "luck_normal", "robustness",
  "Close-game wins above expected (normal-theory expectation)", "close_luck_normal_primary", "robustness",
  "Number of close games", "close_n_primary", "schedule"
)
wide <- wide %>% mutate(close_pct_primary_min3_h1 = ifelse(close_n_primary_h1 >= 3 & close_n_primary_h2 >= 3, close_pct_primary_h1, NA),
                        close_pct_primary_min3_h2 = ifelse(close_n_primary_h1 >= 3 & close_n_primary_h2 >= 3, close_pct_primary_h2, NA))
yoy <- lf %>% select(-half) %>% inner_join(lf %>% select(-half) %>% mutate(season = season - 1L), by = c("season", "team_id"), suffix = c("_h1", "_h2")) %>%
  mutate(close_pct_primary_min3_h1 = ifelse(close_n_primary_h1 >= 3 & close_n_primary_h2 >= 3, close_pct_primary_h1, NA),
         close_pct_primary_min3_h2 = ifelse(close_n_primary_h1 >= 3 & close_n_primary_h2 >= 3, close_pct_primary_h2, NA))
persist <- bind_rows(lapply(seq_len(nrow(measures)), function(i) {
  st <- measures$stem[i]
  bind_rows(
    cor_boot(wide[[paste0(st, "_h1")]], wide[[paste0(st, "_h2")]], wide$team_id, B) %>% mutate(comparison = "First half to second half"),
    cor_boot(yoy[[paste0(st, "_h1")]], yoy[[paste0(st, "_h2")]], yoy$team_id, B) %>% mutate(comparison = "Season to next season"),
    cor_boot(wide[[paste0(st, "_h1")]][wide$season != 2021], wide[[paste0(st, "_h2")]][wide$season != 2021], wide$team_id[wide$season != 2021], B) %>%
      mutate(comparison = "First half to second half, excl. 2020-21")
  ) %>% mutate(measure = measures$measure[i], kind = measures$kind[i])
})) %>% select(measure, kind, comparison, r, ci_low, ci_high, n)
out(persist, "persistence_correlations.csv")

# ---------------------------------------------------------------------------------------------------------------
# 3. Signal vs noise in close games. If close-game results were coin flips weighted by the ratings, a team's
#    close-game wins above expected would have variance sum p(1 - p). Compare the observed spread (full seasons;
#    in-sample ratings absorb a little of each result, which biases the ratio slightly down).
#    Second bound, free of that bias: the half-to-half covariance of close-game luck is the variance of any
#    persistent skill per half; its upper 95% limit, doubled, bounds the skill SD over a season.
# ---------------------------------------------------------------------------------------------------------------
var_dec <- function(luck, null_var, cl) {
  stat <- function(i) c(obs = mean(luck[i]^2), null = mean(null_var[i]))
  idx <- split(seq_along(luck), cl); ids <- names(idx)
  bt <- t(replicate(B, { i <- unlist(idx[sample(ids, length(ids), TRUE)], use.names = FALSE); s <- stat(i); c(s, ratio = s[["obs"]] / s[["null"]], excess = s[["obs"]] - s[["null"]]) }))
  s <- stat(seq_along(luck))
  tibble(observed_var = s[["obs"]], chance_var = s[["null"]], ratio = s[["obs"]] / s[["null"]],
         ratio_ci_low = quantile(bt[, "ratio"], 0.025, names = FALSE), ratio_ci_high = quantile(bt[, "ratio"], 0.975, names = FALSE),
         skill_sd_wins = sqrt(max(0, s[["obs"]] - s[["null"]])),
         skill_sd_wins_upper95 = sqrt(max(0, quantile(bt[, "excess"], 0.975, names = FALSE))),
         team_seasons = length(luck), mean_close_games = NA_real_)
}
vd <- bind_rows(
  var_dec(lf$close_luck_primary, lf$close_v_primary, lf$team_id) %>% mutate(measure = "Close-game wins above expected (margin <= 4 or OT)", mean_close_games = mean(lf$close_n_primary)),
  var_dec(lf$close_luck_le3, lf$close_v_le3, lf$team_id) %>% mutate(measure = "Close-game wins above expected (margin <= 3 or OT)", mean_close_games = mean(lf$close_n_le3)),
  var_dec(lf$close_luck_ot, lf$close_v_ot, lf$team_id) %>% mutate(measure = "Close-game wins above expected (OT only)", mean_close_games = mean(lf$close_n_ot))
) %>% relocate(measure) %>% rename(mean_close_games_per_season = mean_close_games)
cov_bound <- function(st) {
  x <- wide[[paste0(st, "_h1")]]; y <- wide[[paste0(st, "_h2")]]; idx <- split(seq_along(x), wide$team_id); ids <- names(idx)
  bt <- replicate(B, { i <- unlist(idx[sample(ids, length(ids), TRUE)], use.names = FALSE); cov(x[i], y[i]) })
  c(cov = cov(x, y), upper = quantile(bt, 0.975, names = FALSE))
}
cb <- t(sapply(c("close_luck_primary", "close_luck_le3", "close_luck_ot"), cov_bound))
vd <- vd %>% mutate(half_to_half_cov = cb[, "cov"], skill_sd_wins_per_season_upper95_from_halves = 2 * sqrt(pmax(0, cb[, "upper"])))
out(vd, "close_game_variance_vs_chance.csv")

# ---------------------------------------------------------------------------------------------------------------
# 4. Does first-half luck predict the second half beyond the first-half rating? OLS with season effects,
#    SEs clustered by team. If luck were a skill, its coefficient would be positive (1 = fully persistent).
# ---------------------------------------------------------------------------------------------------------------
cluster_ols <- function(y, X, cl) {
  ok <- complete.cases(y, X); y <- y[ok]; X <- cbind(intercept = 1, X[ok, , drop = FALSE]); cl <- cl[ok]
  XtXi <- solve(crossprod(X)); b <- drop(XtXi %*% crossprod(X, y)); u <- drop(y - X %*% b)
  G <- length(unique(cl)); V <- G / (G - 1) * XtXi %*% crossprod(rowsum(X * u, cl)) %*% XtXi
  r2 <- 1 - sum(u^2) / sum((y - mean(y))^2)
  tibble(term = colnames(X), estimate = b, se = sqrt(diag(V)), n = length(y), teams = G, r_squared = r2)
}
sfe <- model.matrix(~ factor(season), wide)[, -1]
wide <- wide %>% mutate(luck_pg_h1 = luck_h1 / games_h1, close_luck_pg_h1 = close_luck_primary_h1 / games_h1,
                        luck_pg_h2 = luck_h2 / games_h2)
reg_rows <- function(label, outcome, X) cluster_ols(outcome, cbind(X, sfe), wide$team_id) %>%
  filter(!grepl("^factor|intercept", term)) %>% mutate(model = label, .before = 1)
regs <- bind_rows(
  reg_rows("H2 win % ~ H2 forecast from H1 ratings + H1 luck per game", wide$win_pct_h2, cbind(h2_forecast_win_pct = wide$h2_forecast_win_pct, luck_per_game_h1 = wide$luck_pg_h1)),
  reg_rows("H2 win % ~ H2 forecast from H1 ratings + H1 close-game luck per game", wide$win_pct_h2, cbind(h2_forecast_win_pct = wide$h2_forecast_win_pct, close_luck_per_game_h1 = wide$close_luck_pg_h1)),
  reg_rows("H2 margin per game ~ H2 forecast margin + H1 luck per game", wide$margin_pg_h2, cbind(h2_forecast_margin = wide$h2_forecast_margin, luck_per_game_h1 = wide$luck_pg_h1)),
  reg_rows("H2 margin per game ~ H2 forecast margin + H1 close-game luck per game", wide$margin_pg_h2, cbind(h2_forecast_margin = wide$h2_forecast_margin, close_luck_per_game_h1 = wide$close_luck_pg_h1)),
  reg_rows("H2 luck per game ~ H1 luck per game", wide$luck_pg_h2, cbind(luck_per_game_h1 = wide$luck_pg_h1)),
  reg_rows("H2 close-game luck per game ~ H1 close-game luck per game", wide$close_luck_primary_h2 / wide$games_h2, cbind(close_luck_per_game_h1 = wide$close_luck_pg_h1)),
  reg_rows("H2 win % ~ H2 forecast from H1 ratings only", wide$win_pct_h2, cbind(h2_forecast_win_pct = wide$h2_forecast_win_pct))
)
out(regs, "luck_regressions.csv")

# Year over year: next season's win % from this season's rating and luck.
yoy <- yoy %>% mutate(luck_pg_h1 = luck_h1 / games_h1)
syfe <- model.matrix(~ factor(season), yoy)[, -1]
regs_yoy <- bind_rows(
  cluster_ols(yoy$win_pct_h2, cbind(rating_this_season = yoy$rating_h1, luck_per_game_this_season = yoy$luck_pg_h1, syfe), yoy$team_id) %>% mutate(model = "Next-season win % ~ rating + luck per game"),
  cluster_ols(yoy$win_pct_h2, cbind(rating_this_season = yoy$rating_h1, close_luck_this_season = yoy$close_luck_primary_h1 / yoy$games_h1, syfe), yoy$team_id) %>% mutate(model = "Next-season win % ~ rating + close-game luck per game")
) %>% filter(!grepl("^factor|intercept", term)) %>% relocate(model)
out(regs_yoy, "luck_regressions_year_over_year.csv")

# ---------------------------------------------------------------------------------------------------------------
# 5. Regression to the mean, by decile of first-half luck.
# ---------------------------------------------------------------------------------------------------------------
dec <- wide %>% mutate(decile = ntile(luck_h1, 10)) %>% group_by(decile) %>%
  summarise(teams = n(), h1_luck = mean(luck_h1), h1_se = sd(luck_h1) / sqrt(n()), h2_luck = mean(luck_h2), h2_se = sd(luck_h2) / sqrt(n()),
            h1_close_luck = mean(close_luck_primary_h1), h2_close_luck = mean(close_luck_primary_h2),
            h1_win_pct = mean(win_pct_h1), h2_win_pct = mean(win_pct_h2), h2_forecast_win_pct = mean(h2_forecast_win_pct, na.rm = TRUE),
            h1_rating = mean(rating_h1), h2_rating = mean(rating_h2), h1_games = mean(games_h1), h2_games = mean(games_h2), .groups = "drop")
out(dec, "regression_to_mean_by_decile.csv")

# headline numbers
pr <- function(m, cmp = "First half to second half") persist %>% filter(measure == m, comparison == cmp)
top <- dec %>% filter(decile == 10); bot <- dec %>% filter(decile == 1)
headline <- tibble(
  quantity = c("team-seasons (both halves >= 8 games)", "mean games per half", "mean close games per half (primary)",
               "share of games that are close (primary)", "top-decile H1 wins above expected", "top-decile H2 wins above expected",
               "bottom-decile H1 wins above expected", "bottom-decile H2 wins above expected"),
  value = c(nrow(wide), mean(c(wide$games_h1, wide$games_h2)), mean(c(wide$close_n_primary_h1, wide$close_n_primary_h2)),
            mean(is_close(tg_full$margin, tg_full$ot, defs$primary)), top$h1_luck, top$h2_luck, bot$h1_luck, bot$h2_luck))
out(headline, "headline_numbers.csv")

# ---------------------------------------------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------------------------------------------
p1d <- dec %>% select(decile, h1_luck, h1_se, h2_luck, h2_se) %>%
  pivot_longer(-decile, names_to = c("half", ".value"), names_pattern = "(h[12])_(.*)") %>%
  mutate(half = ifelse(half == "h1", "First half (how teams were sorted)", "Second half (same teams)"))
p1 <- ggplot(p1d, aes(decile, luck, colour = half)) +
  geom_hline(yintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_line(linewidth = 0.9) +
  geom_errorbar(aes(ymin = luck - 1.96 * se, ymax = luck + 1.96 * se), width = 0, linewidth = 0.8) +
  geom_point(size = 2.6) +
  annotate("text", x = 10, y = top$h1_luck, label = sprintf("%+.1f", top$h1_luck), hjust = -0.4, colour = cs_pal[["orange"]], size = 3.6) +
  annotate("text", x = 10, y = top$h2_luck, label = sprintf("%+.1f", top$h2_luck), hjust = -0.4, vjust = -0.3, colour = cs_pal[["blue"]], size = 3.6) +
  annotate("text", x = 1, y = bot$h1_luck, label = sprintf("%+.1f", bot$h1_luck), hjust = 1.4, colour = cs_pal[["orange"]], size = 3.6) +
  annotate("text", x = 1, y = bot$h2_luck, label = sprintf("%+.1f", bot$h2_luck), hjust = 1.4, vjust = -0.3, colour = cs_pal[["blue"]], size = 3.6) +
  scale_colour_manual(values = c(cs_pal[["orange"]], cs_pal[["blue"]])) +
  scale_x_continuous(breaks = 1:10, labels = c("1\nunluckiest", 2:9, "10\nluckiest"), expand = expansion(add = 0.8)) +
  labs(title = sprintf("The luckiest tenth of teams won %.1f games more than expected, then %+.1f the rest of the season", top$h1_luck, top$h2_luck),
       subtitle = "Wins minus rating-expected wins, by decile of first-half luck. Each half is measured with ratings fit on that half's games only.\n95% intervals.",
       x = "Decile of first-half luck", y = "Wins above expected (per half-season)",
       caption = sprintf("Source: ESPN via hoopR. %s team-seasons, 2007-08 to 2025-26, D1 vs D1 regular season, about %.0f games per half.",
                         format(nrow(wide), big.mark = ","), mean(c(wide$games_h1, wide$games_h2)))) +
  theme_cs()
save_fig(p1, fig("01_regression_to_the_mean.png"), width = 9.5, height = 5.4)

main_rows <- c("Point margin per game", "Rating (opponent-adjusted margin)", "Win percentage", "Wins above expected (all games)",
               "Close-game wins above expected", "Close-game win percentage")
p2d <- persist %>% filter(measure %in% main_rows, comparison != "First half to second half, excl. 2020-21") %>%
  mutate(measure = factor(measure, levels = rev(main_rows)))
p2 <- ggplot(p2d, aes(r, measure, colour = comparison)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high), orientation = "y", width = 0, linewidth = 0.9, position = position_dodge(width = 0.6)) +
  geom_point(size = 2.6, position = position_dodge(width = 0.6)) +
  geom_text(aes(x = ci_high + 0.015, label = sprintf("%.2f", r)), position = position_dodge(width = 0.6), hjust = 0, size = 3.1, show.legend = FALSE) +
  scale_colour_manual(values = c(cs_pal[["blue"]], cs_pal[["orange"]])) +
  scale_x_continuous(limits = c(-0.15, 1), breaks = seq(0, 1, 0.2)) +
  labs(title = sprintf("Point margin carries over (r = %.2f); close-game luck does not (r = %.2f)",
                       pr("Point margin per game")$r, pr("Close-game wins above expected")$r),
       subtitle = "Correlation of each measure between the two halves of a season, and between one season and the next.\n95% bootstrap intervals, resampling teams.",
       x = "Correlation", y = NULL,
       caption = sprintf("Source: ESPN via hoopR, 2007-08 to 2025-26. Halves: %s team-seasons. Seasons: %s consecutive pairs. Close = final margin <= 4 or overtime.",
                         format(nrow(wide), big.mark = ","), format(nrow(yoy), big.mark = ","))) +
  theme_cs()
save_fig(p2, fig("02_what_persists.png"), width = 9.5, height = 5.6)

p3d <- calib %>% select(edge, expected_calibrated, expected_normal_theory) %>%
  pivot_longer(-edge, names_to = "model", values_to = "expected") %>%
  mutate(model = recode(model, expected_calibrated = "Calibrated expectation (used)", expected_normal_theory = "Normal-theory expectation"))
gap <- calib %>% filter(edge == "9-13")
p3 <- ggplot(calib, aes(edge)) +
  geom_hline(yintercept = 0.5, colour = cs_ink[["baseline"]], linewidth = 0.6, linetype = "22") +
  geom_line(data = p3d, aes(y = expected, colour = model, group = model), linewidth = 0.9) +
  geom_point(data = p3d, aes(y = expected, colour = model), size = 2, shape = 15) +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 0.8, colour = cs_ink[["primary"]]) +
  geom_point(aes(y = actual_win_pct), size = 2.8, colour = cs_ink[["primary"]]) +
  annotate("text", x = 0.6, y = 0.508, label = "coin flip", hjust = 0, colour = cs_ink[["muted"]], size = 3.2) +
  scale_colour_manual(values = c(cs_pal[["blue"]], cs_pal[["orange"]])) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(title = "Favorites win more close games than a coin flip, and more than a simple normal model predicts",
       subtitle = sprintf("Favorite's actual win rate in close games (black dots, 95%% interval) against two expectations. At a 9-13 point edge:\nactual %.0f%%, normal theory %.0f%%, calibrated (fit leaving out each season) %.0f%%.",
                          100 * gap$actual_win_pct, 100 * gap$expected_normal_theory, 100 * gap$expected_calibrated),
       x = "Favorite's predicted margin (points)", y = "Favorite's win rate in close games",
       caption = sprintf("Source: ESPN via hoopR, 2007-08 to 2025-26. %s close games (final margin <= 4 or overtime), full-season ratings.",
                         format(sum(calib$close_games), big.mark = ","))) +
  theme_cs()
save_fig(p3, fig("03_close_game_calibration.png"), width = 9, height = 5.2)

cat(sprintf("done in %.1f s\n", as.numeric(difftime(Sys.time(), t_start, units = "secs"))))
