# Study 04: how big is home-court advantage, is it shrinking, and do crowds cause it?
# Public data only (ESPN via hoopR, cached under data/cache). Run from the repo root:
#   Rscript studies/04-home-court-advantage/analysis.R
source("R/data.R"); source("R/ratings.R"); source("R/theme.R")
suppressPackageStartupMessages({ library(tidyr); library(readr) })
set.seed(20261105)
t_start <- Sys.time()
study <- "studies/04-home-court-advantage"
fig <- function(f) file.path(study, "figures", f)
out <- function(df, f) { dir.create(file.path(study, "results"), FALSE, TRUE); write_csv(df, file.path(study, "results", f)); invisible(df) }
B <- 200
lab_season <- function(s) sprintf("%d-%02d", s - 1, s %% 100)

# ---------------------------------------------------------------------------------------------------------------
# Data. D1 vs D1 games. ESPN only flags neutral sites from 2007-08 on, so a game also counts as neutral when it is
# not played at the home team's main venue that season (its most-used venue). Games with no venue id are dropped
# (they are 9-20% of 2001-02 to 2007-08 and 18-33% of them were neutral where ESPN flags exist); none after 2012-13.
# ---------------------------------------------------------------------------------------------------------------
games <- cbb_games(2002:2026) %>% d1_only()
main_venue <- games %>% filter(!is.na(venue_id)) %>% count(season, home_id, venue_id) %>%
  group_by(season, home_id) %>% slice_max(n, n = 1, with_ties = FALSE) %>% ungroup() %>%
  select(season, home_id, main_venue = venue_id)
games <- games %>% left_join(main_venue, by = c("season", "home_id")) %>%
  mutate(neutral_espn = neutral, venue_known = !is.na(venue_id),
         neutral = as.integer(neutral_espn == 1 | (venue_known & venue_id != main_venue)))
reg <- games %>% filter(season_type == 2, venue_known)

quality <- games %>% filter(season_type == 2) %>% group_by(season) %>%
  summarise(games = n(), venue_missing_share = mean(!venue_known),
            espn_neutral_share = mean(neutral_espn), harmonized_neutral_share = mean(neutral[venue_known]),
            agreement_with_espn = ifelse(min(season) >= 2008, mean((neutral == neutral_espn)[venue_known]), NA),
            home_games_with_attendance = mean(!is.na(attendance[neutral == 0 & venue_known])),
            zero_attendance_home_games = sum(attendance_raw[neutral == 0 & venue_known] == 0, na.rm = TRUE),
            .groups = "drop")
out(quality, "data_quality_by_season.csv")

# ---------------------------------------------------------------------------------------------------------------
# A ridge design with any set of home-advantage columns. Same model as fit_ratings() (ratings penalized by
# lambda = 1, home terms unpenalized); bootstrap reps reweight games instead of rebuilding the matrix.
# ---------------------------------------------------------------------------------------------------------------
make_design <- function(g, H, lambda = 1) {
  teams <- sort(unique(c(g$home_id, g$away_id))); n <- nrow(g); k <- length(teams)
  Xt <- sparseMatrix(i = rep(seq_len(n), 2), j = c(match(g$home_id, teams), match(g$away_id, teams)),
                     x = rep(c(1, -1), each = n), dims = c(n, k))
  H <- as(Matrix(as.matrix(H), sparse = TRUE), "CsparseMatrix")
  list(X = cbind(Xt, H), y = g$margin, k = k, hnames = colnames(H), teams = teams,
       P = Diagonal(k + ncol(H), c(rep(lambda, k), rep(1e-6, ncol(H)))))   # ~0: keeps a term solvable when a bootstrap rep drops all its games
}
solve_design <- function(d, w = NULL, y = d$y) {
  Xw <- if (is.null(w)) d$X else d$X * w
  b <- as.numeric(solve(crossprod(d$X, Xw) + d$P, crossprod(Xw, y)))
  setNames(b[d$k + seq_along(d$hnames)], d$hnames)
}
boot_design <- function(d, B, y = d$y) {
  n <- length(d$y)
  do.call(rbind, lapply(seq_len(B), function(i) solve_design(d, tabulate(sample.int(n, n, TRUE), n), y = y)))   # B x terms
}
ci <- function(x) quantile(x, c(0.025, 0.975), names = FALSE)

# sanity check: one home term reproduces fit_ratings()
chk <- reg %>% filter(season == 2026)
stopifnot(abs(solve_design(make_design(chk, cbind(hca = 1 - chk$neutral))) - fit_ratings(chk)$hca) < 1e-6)

# ---------------------------------------------------------------------------------------------------------------
# 1. HCA by season, 2001-02 to 2025-26, with bootstrap CIs (games resampled within season).
#    Also: ESPN's own neutral flag (2007-08 on) and HCA per 100 possessions (team box, 2007-08 on).
# ---------------------------------------------------------------------------------------------------------------
poss <- cbb_team_box(2008:2026) %>% group_by(game_id) %>% summarise(game_poss = mean(poss), n_team = n(), .groups = "drop") %>%
  filter(n_team == 2, game_poss > 40, game_poss < 110)
boot_draws <- list()
by_season <- bind_rows(lapply(2002:2026, function(s) {
  g <- reg %>% filter(season == s)
  d <- make_design(g, cbind(hca = 1 - g$neutral))
  est <- solve_design(d); bt <- boot_design(d, B)[, 1]
  boot_draws[[as.character(s)]] <<- bt
  # robustness: ESPN's own flag and all games (before 2007-08 the flag is never set, so every game counts as a home game)
  espn <- fit_ratings(games %>% filter(season == s, season_type == 2) %>% mutate(neutral = neutral_espn))$hca
  p100 <- c(NA, NA, NA); pace <- NA
  if (s >= 2008) {
    gp <- g %>% inner_join(poss, by = "game_id")
    dp <- make_design(gp, cbind(hca = 1 - gp$neutral))
    y100 <- 100 * gp$margin / gp$game_poss
    bp <- boot_design(dp, B, y = y100)[, 1]
    p100 <- c(solve_design(dp, y = y100), ci(bp)); pace <- mean(gp$game_poss)
  }
  tibble(season = s, season_label = lab_season(s), hca = unname(est), ci_low = ci(bt)[1], ci_high = ci(bt)[2], se = sd(bt),
         games = nrow(g), home_games = sum(g$neutral == 0), hca_espn_neutral_flag = espn,
         median_home_attendance = median(g$attendance[g$neutral == 0], na.rm = TRUE),
         home_games_with_attendance = mean(!is.na(g$attendance[g$neutral == 0])),
         hca_per100 = p100[1], hca_per100_ci_low = p100[2], hca_per100_ci_high = p100[3], possessions_per_team_game = pace,
         neutral_source = ifelse(s < 2008, "venue only (ESPN flag absent)", "ESPN flag or venue"))
}))
out(by_season, "hca_by_season.csv")

draws <- do.call(cbind, boot_draws)          # B x 25
early <- as.character(2002:2006); late <- as.character(2022:2026)
diff_draws <- rowMeans(draws[, late]) - rowMeans(draws[, early])
normal <- by_season %>% filter(season != 2021)
wls <- lm(hca ~ I(season - 2002), data = normal, weights = 1 / se^2)
wls08 <- lm(hca ~ I(season - 2002), data = normal %>% filter(season >= 2008), weights = 1 / se^2)
wls_ols_se <- function(m) summary(m)$coefficients[2, 1:2]
trend <- tibble(
  quantity = c("mean HCA 2001-02 to 2005-06", "mean HCA 2021-22 to 2025-26", "change, late minus early",
               "linear trend per decade (2001-02 to 2025-26, excl. 2020-21)", "linear trend per decade (2007-08 on, excl. 2020-21)",
               "HCA 2020-21", "mean HCA 2018-19 and 2019-20"),
  estimate = c(mean(by_season$hca[by_season$season %in% 2002:2006]), mean(by_season$hca[by_season$season %in% 2022:2026]),
               mean(by_season$hca[by_season$season %in% 2022:2026]) - mean(by_season$hca[by_season$season %in% 2002:2006]),
               10 * wls_ols_se(wls)[1], 10 * wls_ols_se(wls08)[1],
               by_season$hca[by_season$season == 2021], mean(by_season$hca[by_season$season %in% 2019:2020])),
  ci_low = c(ci(rowMeans(draws[, early]))[1], ci(rowMeans(draws[, late]))[1], ci(diff_draws)[1],
             10 * (wls_ols_se(wls)[1] - 1.96 * wls_ols_se(wls)[2]), 10 * (wls_ols_se(wls08)[1] - 1.96 * wls_ols_se(wls08)[2]),
             by_season$ci_low[by_season$season == 2021], ci(rowMeans(draws[, c("2019", "2020")]))[1]),
  ci_high = c(ci(rowMeans(draws[, early]))[2], ci(rowMeans(draws[, late]))[2], ci(diff_draws)[2],
              10 * (wls_ols_se(wls)[1] + 1.96 * wls_ols_se(wls)[2]), 10 * (wls_ols_se(wls08)[1] + 1.96 * wls_ols_se(wls08)[2]),
              by_season$ci_high[by_season$season == 2021], ci(rowMeans(draws[, c("2019", "2020")]))[2]))
# residual scatter around the trend line vs what sampling error alone would give
trend_chi2 <- sum(residuals(wls)^2 * weights(wls)); trend_df <- df.residual(wls)
trend <- trend %>% bind_rows(tibble(quantity = "weighted residual chi-square around the trend (df in ci_low)",
                                    estimate = trend_chi2, ci_low = trend_df, ci_high = pchisq(trend_chi2, trend_df, lower.tail = FALSE)))
out(trend, "hca_trend_summary.csv")

# ---------------------------------------------------------------------------------------------------------------
# Conferences, derived from the data: teams linked by conference games form one connected component per season,
# and each component is named by an anchor school (first match in this list wins).
# ---------------------------------------------------------------------------------------------------------------
components <- function(edges) {
  nodes <- unique(c(edges$a, edges$b)); par <- setNames(nodes, nodes)
  find <- function(x) { while (par[[x]] != x) { par[[x]] <<- par[[par[[x]]]]; x <- par[[x]] }; x }
  for (i in seq_len(nrow(edges))) { ra <- find(edges$a[i]); rb <- find(edges$b[i]); if (ra != rb) par[[ra]] <- rb }
  tibble(team_id = nodes, comp = vapply(nodes, find, ""))
}
anchors <- c("ACC" = "Duke Blue Devils", "Big Ten" = "Indiana Hoosiers", "SEC" = "Kentucky Wildcats",
  "Big 12" = "Kansas Jayhawks", "Big East" = "Georgetown Hoyas", "WCC" = "Gonzaga Bulldogs", "Pac-12" = "Oregon State Beavers",
  "American" = "Memphis Tigers", "Mountain West" = "Boise State Broncos", "Atlantic 10" = "Dayton Flyers",
  "Missouri Valley" = "Bradley Braves", "MAC" = "Akron Zips", "Conference USA" = "Western Kentucky Hilltoppers",
  "Sun Belt" = "Arkansas State Red Wolves", "WAC" = "Utah Valley Wolverines", "Big West" = "UC Irvine Anteaters",
  "Big Sky" = "Montana Grizzlies", "Summit" = "South Dakota State Jackrabbits", "Horizon" = "Green Bay Phoenix",
  "MAAC" = "Iona Gaels", "CAA" = "Hofstra Pride", "Ivy" = "Princeton Tigers", "Patriot" = "Colgate Raiders",
  "America East" = "Vermont Catamounts", "NEC" = "Central Connecticut Blue Devils", "Ohio Valley" = "Morehead State Eagles",
  "Big South" = "Winthrop Eagles", "SoCon" = "Furman Paladins", "Southland" = "Lamar Cardinals", "ASUN" = "Lipscomb Bisons",
  "SWAC" = "Alcorn State Braves", "MEAC" = "Howard Bison", "MEAC" = "Norfolk State Spartans",
  "Southland" = "Northwestern State Demons")
conf_map <- function(seasons) {
  ids <- games %>% filter(season == 2026) %>% distinct(team_id = home_id, name = home_name)
  anchor_ids <- ids$team_id[match(anchors, ids$name)]
  if (anyNA(anchor_ids)) stop("anchor not found: ", paste(anchors[is.na(anchor_ids)], collapse = ", "))
  bind_rows(lapply(seasons, function(s) {
    cc <- components(games %>% filter(season == s, conf_game == 1) %>% distinct(a = home_id, b = away_id))
    lab <- cc %>% mutate(pri = match(team_id, anchor_ids)) %>% filter(!is.na(pri)) %>% group_by(comp) %>%
      summarise(conf = names(anchors)[min(pri)], .groups = "drop")
    cc %>% left_join(lab, by = "comp") %>% mutate(season = s, conf = coalesce(conf, "Unlabeled"))
  }))
}
confs <- conf_map(2021:2026)

# ---------------------------------------------------------------------------------------------------------------
# 2. 2020-21: empty arenas (ESPN attendance 0) vs games with some fans, and the specifications that compare like
#    with like: within conference (conference-specific HCA) and within home team (team-specific HCA).
# ---------------------------------------------------------------------------------------------------------------
g21 <- reg %>% filter(season == 2021) %>%
  left_join(confs %>% filter(season == 2021) %>% select(home_id = team_id, home_conf = conf), by = "home_id") %>%
  mutate(home_conf = coalesce(home_conf, "Unlabeled"))
nn <- 1 - g21$neutral
stopifnot(!anyNA(g21$attendance_raw[nn == 1]))
fans <- as.integer(g21$attendance_raw > 0)
crowd <- cut(g21$attendance_raw, c(-Inf, 0, 999, Inf), labels = c("empty", "1-999", "1,000+"))
hosts <- sort(unique(g21$home_id[nn == 1]))
team_fe <- sparseMatrix(i = which(nn == 1), j = match(g21$home_id[nn == 1], hosts), x = 1, dims = c(nrow(g21), length(hosts)))
colnames(team_fe) <- paste0("team_", hosts)
conf_fe <- model.matrix(~ home_conf - 1, g21) * nn
late <- as.integer(g21$date >= as.Date("2021-02-01"))
specs <- list(
  "Pooled: empty vs some fans" = cbind(empty = nn * (1 - fans), fans = nn * fans),
  "Within conference" = cbind(conf_fe, fans_shift = nn * fans),
  "Within home team" = cbind(team_fe, fans_shift = nn * fans),
  "Within home team, + conference-game and Feb-Mar terms" = cbind(team_fe, fans_shift = nn * fans, conf_shift = nn * g21$conf_game, late_shift = nn * late),
  "Pooled: crowd size" = cbind(empty = nn * (crowd == "empty"), small = nn * (crowd == "1-999"), large = nn * (crowd == "1,000+")),
  "Within home team: crowd size" = cbind(team_fe, small_shift = nn * (crowd == "1-999"), large_shift = nn * (crowd == "1,000+"))
)
covid <- bind_rows(lapply(names(specs), function(nm) {
  d <- make_design(g21, specs[[nm]]); est <- solve_design(d); bt <- boot_design(d, B)
  keep <- intersect(c("empty", "fans", "small", "large", "fans_shift", "small_shift", "large_shift"), names(est))
  rows <- lapply(keep, function(k) tibble(spec = nm, term = k, estimate = est[[k]], ci_low = ci(bt[, k])[1], ci_high = ci(bt[, k])[2], se = sd(bt[, k])))
  if (all(c("empty", "fans") %in% names(est))) {
    dd <- bt[, "fans"] - bt[, "empty"]
    rows <- c(rows, list(tibble(spec = nm, term = "fans_minus_empty", estimate = est[["fans"]] - est[["empty"]], ci_low = ci(dd)[1], ci_high = ci(dd)[2], se = sd(dd))))
  }
  if (all(c("empty", "large") %in% names(est))) {
    dd <- bt[, "large"] - bt[, "empty"]
    rows <- c(rows, list(tibble(spec = nm, term = "large_minus_empty", estimate = est[["large"]] - est[["empty"]], ci_low = ci(dd)[1], ci_high = ci(dd)[2], se = sd(dd))))
  }
  bind_rows(rows)
}))
host_mix <- g21 %>% filter(neutral == 0) %>% group_by(home_id) %>% summarise(n = n(), nf = sum(attendance_raw > 0), .groups = "drop")
covid_counts <- tibble(
  quantity = c("home games", "home games with attendance 0", "home games with attendance > 0", "home games with 1-999", "home games with 1,000+",
               "home teams", "home teams hosting both kinds", "home games at those teams", "median attendance when > 0"),
  value = c(sum(nn), sum(nn * (1 - fans)), sum(nn * fans), sum(nn * (crowd == "1-999")), sum(nn * (crowd == "1,000+")),
            nrow(host_mix), sum(host_mix$nf > 0 & host_mix$nf < host_mix$n), sum(host_mix$n[host_mix$nf > 0 & host_mix$nf < host_mix$n]),
            median(g21$attendance_raw[nn == 1 & fans == 1])))
fans_by_conf <- g21 %>% filter(neutral == 0) %>% group_by(home_conf) %>%
  summarise(home_games = n(), share_with_fans = mean(attendance_raw > 0), median_attendance_when_fans = median(attendance_raw[attendance_raw > 0]), .groups = "drop") %>%
  arrange(desc(share_with_fans))
out(covid, "covid_2020_21_hca.csv"); out(covid_counts, "covid_2020_21_counts.csv"); out(fans_by_conf, "covid_2020_21_fans_by_conference.csv")
out(reg %>% filter(season == 2022, neutral == 0) %>% group_by(month = format(date, "%Y-%m")) %>%
      summarise(home_games = n(), attendance_zero = sum(attendance_raw == 0, na.rm = TRUE), .groups = "drop"),
    "empty_arena_games_by_month_2021_22.csv")

# Placebo: in normal seasons a 0 just means ESPN has no number. If those games also showed a gap, the 2020-21 gap
# could be a recording artifact.
placebo <- bind_rows(lapply(c(2018:2020, 2022:2026), function(s) {
  g <- reg %>% filter(season == s); n0 <- 1 - g$neutral; f <- as.integer(coalesce(g$attendance_raw, 0L) > 0)
  d <- make_design(g, cbind(empty = n0 * (1 - f), fans = n0 * f)); est <- solve_design(d); bt <- boot_design(d, 100)
  tibble(season = s, zero_attendance_home_games = sum(n0 * (1 - f)), diff_fans_minus_zero = est[["fans"]] - est[["empty"]], se = sd(bt[, "fans"] - bt[, "empty"]))
}))
pooled_placebo <- with(placebo, c(est = sum(diff_fans_minus_zero / se^2) / sum(1 / se^2), se = sqrt(1 / sum(1 / se^2))))
out(placebo %>% bind_rows(tibble(season = NA, zero_attendance_home_games = sum(placebo$zero_attendance_home_games),
                                 diff_fans_minus_zero = pooled_placebo[["est"]], se = pooled_placebo[["se"]])),
    "placebo_zero_attendance_normal_seasons.csv")

# ---------------------------------------------------------------------------------------------------------------
# 3. Dose-response in normal seasons: the home edge left after ratings (margin minus rating difference) against
#    attendance relative to the venue's own median that season. Missing attendance stays missing; seasons where
#    under 80% of home games have a number are skipped (2008-09, 2009-10, 2016-17), as is 2020-21.
# ---------------------------------------------------------------------------------------------------------------
att_seasons <- quality %>% filter(home_games_with_attendance >= 0.8, season != 2021) %>% pull(season)
edges <- bind_rows(lapply(att_seasons, function(s) {
  g <- reg %>% filter(season == s); f <- fit_ratings(g)
  r <- setNames(f$ratings$rating, f$ratings$team_id)
  g %>% mutate(pred0 = unname(r[home_id] - r[away_id]), home_edge = margin - pred0, season_hca = f$hca)
}))
home <- edges %>% filter(neutral == 0) %>% arrange(season, date) %>%
  group_by(season, venue_id) %>% mutate(venue_n = sum(!is.na(attendance)), venue_median = median(attendance, na.rm = TRUE)) %>% ungroup() %>%
  filter(!is.na(attendance), venue_n >= 5) %>%
  mutate(log_ratio = log(attendance / venue_median))
trimmed <- sum(abs(home$log_ratio) > 1.5)
home <- home %>% filter(abs(log_ratio) <= 1.5)
# placebo outcomes: the home team's next and previous true road games (within 14 days), result vs the ratings
# from that team's side. A crowd can't change a road game, so a slope there is confounding (form, schedule).
road <- edges %>% filter(neutral == 0) %>%
  transmute(season, team_id = away_id, road_date = date, road_perf = -(home_edge - season_hca), road_gap = -pred0,
            road_conf = conf_game, road_weekend = as.integer(format(date, "%u") %in% c("6", "7")))
near_road <- function(direction) {
  j <- home %>% select(game_id, season, team_id = home_id, date) %>%
    inner_join(road, by = c("season", "team_id"), relationship = "many-to-many")
  j <- if (direction == "next") filter(j, road_date > date, road_date <= date + 14) %>% group_by(game_id) %>% slice_min(road_date, n = 1, with_ties = FALSE)
       else filter(j, road_date < date, road_date >= date - 14) %>% group_by(game_id) %>% slice_max(road_date, n = 1, with_ties = FALSE)
  j %>% ungroup() %>% select(game_id, road_perf, road_gap, road_conf, road_weekend) %>%
    rename_with(~ paste0(direction, "_", .x), -game_id)
}
home <- home %>% left_join(near_road("next"), by = "game_id") %>% left_join(near_road("prev"), by = "game_id") %>%
  mutate(month = factor(format(date, "%m")), weekend = as.integer(format(date, "%u") %in% c("6", "7")),
         team_season = paste(season, home_id), perf = home_edge - season_hca)

cluster_fit <- function(y, X, cl, within = NULL) {
  ok <- stats::complete.cases(y, X); y <- y[ok]; X <- X[ok, , drop = FALSE]; cl <- cl[ok]
  if (!is.null(within)) {
    w <- within[ok]
    y <- y - ave(y, w); X <- apply(X, 2, function(v) v - ave(v, w))
    keep <- apply(X, 2, function(v) sd(v) > 1e-9); X <- X[, keep, drop = FALSE]
  } else X <- cbind(intercept = 1, X)
  XtXi <- solve(crossprod(X)); b <- XtXi %*% crossprod(X, y); u <- as.numeric(y - X %*% b)
  G <- length(unique(cl)); meat <- crossprod(rowsum(X * u, cl))
  V <- G / (G - 1) * XtXi %*% meat %*% XtXi
  list(b = b[, 1], se = sqrt(diag(V)), n = length(y), clusters = G)
}
ctrl <- function(d, season_fe = TRUE) {
  m <- cbind(log_ratio = d$log_ratio, pred0 = d$pred0, conf_game = d$conf_game, weekend = d$weekend,
             model.matrix(~ month, d)[, -1, drop = FALSE])
  if (season_fe) m <- cbind(m, model.matrix(~ factor(season), d)[, -1, drop = FALSE])
  m
}
slope_rows <- function(label, f) tibble(model = label, slope_per_log_unit = f$b[["log_ratio"]], se = f$se[["log_ratio"]],
                                         ci_low = f$b[["log_ratio"]] - 1.96 * f$se[["log_ratio"]], ci_high = f$b[["log_ratio"]] + 1.96 * f$se[["log_ratio"]],
                                         games = f$n, venue_clusters = f$clusters)
road_ctrl <- function(d, p) cbind(ctrl(d, FALSE), road_gap = d[[paste0(p, "_road_gap")]], road_conf = d[[paste0(p, "_road_conf")]],
                                   road_weekend = d[[paste0(p, "_road_weekend")]])
fe <- function(y, X, d) cluster_fit(y, X, d$venue_id, within = d$team_season)
nc <- home$conf_game == 0
slopes <- bind_rows(
  slope_rows("Home edge ~ crowd ratio (season effects only)", cluster_fit(home$perf, cbind(log_ratio = home$log_ratio, model.matrix(~ factor(season), home)[, -1]), home$venue_id)),
  slope_rows("+ opponent gap, conference game, weekend, month", cluster_fit(home$perf, ctrl(home), home$venue_id)),
  slope_rows("+ home team-season fixed effects (main)", fe(home$perf, ctrl(home, FALSE), home)),
  slope_rows("Main, conference games only", fe(home$perf[!nc], ctrl(home[!nc, ], FALSE)[, -3], home[!nc, ])),
  slope_rows("Main, non-conference games only", fe(home$perf[nc], ctrl(home[nc, ], FALSE)[, -3], home[nc, ])),
  slope_rows("Placebo: same team's previous road game", fe(home$prev_road_perf, road_ctrl(home, "prev"), home)),
  slope_rows("Placebo: same team's next road game", fe(home$next_road_perf, road_ctrl(home, "next"), home))
)
out(slopes %>% mutate(trimmed_games_abs_log_ratio_over_1_5 = trimmed, seasons = paste(att_seasons, collapse = " ")), "attendance_dose_response_slopes.csv")

# Binned view: raw home edge, and the same after removing team-season means and the controls (Frisch-Waugh).
fwl <- local({
  X <- ctrl(home, FALSE)[, -1]; y <- home$perf - ave(home$perf, home$team_season)
  X <- apply(X, 2, function(v) v - ave(v, home$team_season)); X <- X[, apply(X, 2, sd) > 1e-9]
  x <- home$log_ratio - ave(home$log_ratio, home$team_season)
  list(y = as.numeric(residuals(lm(y ~ X - 1))), x = as.numeric(residuals(lm(x ~ X - 1))))
})
home <- home %>% mutate(raw_bin = ntile(log_ratio, 10), adj_x = fwl$x, adj_bin = ntile(adj_x, 10), adj_edge = fwl$y + mean(home_edge))
bins <- bind_rows(
  home %>% group_by(bin = raw_bin) %>%
    summarise(view = "Raw: crowd vs the venue's median", games = n(), mean_log_ratio = mean(log_ratio), se = sd(home_edge) / sqrt(n()),
              home_edge = mean(home_edge), mean_opponent_gap = mean(pred0), share_conference = mean(conf_game), .groups = "drop"),
  home %>% group_by(bin = adj_bin) %>%
    summarise(view = "Adjusted: same team-season, opponent and calendar held fixed", games = n(), mean_log_ratio = mean(adj_x), se = sd(adj_edge) / sqrt(n()),
              home_edge = mean(adj_edge), mean_opponent_gap = mean(pred0), share_conference = mean(conf_game), .groups = "drop")
) %>% mutate(crowd_vs_usual = exp(mean_log_ratio), ci_low = home_edge - 1.96 * se, ci_high = home_edge + 1.96 * se)
out(bins, "attendance_dose_response_bins.csv")

# ---------------------------------------------------------------------------------------------------------------
# 4. HCA by conference (conference games, 2021-22 to 2025-26 pooled) with empirical-Bayes shrinkage, and
#    conference vs non-conference games by season.
# ---------------------------------------------------------------------------------------------------------------
cg <- bind_rows(lapply(2022:2026, function(s) {
  g <- reg %>% filter(season == s); f <- fit_ratings(g)
  r <- setNames(f$ratings$rating, f$ratings$team_id)
  cm <- confs %>% filter(season == s) %>% select(team_id, conf)
  g %>% filter(neutral == 0, conf_game == 1) %>% mutate(home_edge = margin - unname(r[home_id] - r[away_id])) %>%
    left_join(cm %>% rename(home_id = team_id, home_conf = conf), by = "home_id") %>%
    left_join(cm %>% rename(away_id = team_id, away_conf = conf), by = "away_id") %>%
    filter(home_conf == away_conf, home_conf != "Unlabeled")
}))
conf_tab <- cg %>% group_by(conference = home_conf) %>%
  summarise(games = n(), raw = mean(home_edge), se = sd(home_edge) / sqrt(n()), .groups = "drop")
# Random-effects shrinkage. tau^2 (spread of true conference HCAs) by Paule-Mandel, with a Q-profile 95% CI.
gen_q <- function(tau2, y, s) { w <- 1 / (s^2 + tau2); sum(w * (y - sum(w * y) / sum(w))^2) }
tau2_at <- function(target, y, s) if (gen_q(0, y, s) <= target) 0 else uniroot(function(t) gen_q(t, y, s) - target, c(0, 100))$root
K <- nrow(conf_tab)
tau2 <- tau2_at(K - 1, conf_tab$raw, conf_tab$se)
tau2_ci <- c(tau2_at(qchisq(0.975, K - 1), conf_tab$raw, conf_tab$se), tau2_at(qchisq(0.025, K - 1), conf_tab$raw, conf_tab$se))
w_re <- 1 / (conf_tab$se^2 + tau2); mu <- sum(w_re * conf_tab$raw) / sum(w_re)
Q <- gen_q(0, conf_tab$raw, conf_tab$se)
shrink <- tau2 / (tau2 + conf_tab$se^2)
conf_att <- cg %>% group_by(conference = home_conf) %>% summarise(median_attendance = median(attendance, na.rm = TRUE), .groups = "drop")
conf_tab <- conf_tab %>% mutate(raw_ci_low = raw - 1.96 * se, raw_ci_high = raw + 1.96 * se,
                                shrunk = mu + shrink * (raw - mu), post_sd = sqrt(shrink * se^2),
                                shrunk_ci_low = shrunk - 1.96 * post_sd, shrunk_ci_high = shrunk + 1.96 * post_sd) %>%
  left_join(conf_att, by = "conference") %>% arrange(desc(shrunk))
out(conf_tab, "hca_by_conference.csv")
att_cor <- cor.test(conf_tab$raw, log(conf_tab$median_attendance))
conf_het <- tibble(quantity = c("random-effects mean HCA, conference games", "between-conference SD of true HCA (tau, Paule-Mandel)",
                                "Cochran Q", "Q degrees of freedom", "Q p-value", "conferences", "games",
                                "correlation of conference HCA with log median attendance"),
                   estimate = c(mu, sqrt(tau2), Q, K - 1, pchisq(Q, K - 1, lower.tail = FALSE), K, nrow(cg), unname(att_cor$estimate)),
                   ci_low = c(mu - 1.96 / sqrt(sum(w_re)), sqrt(tau2_ci[1]), NA, NA, NA, NA, NA, att_cor$conf.int[1]),
                   ci_high = c(mu + 1.96 / sqrt(sum(w_re)), sqrt(tau2_ci[2]), NA, NA, NA, NA, NA, att_cor$conf.int[2]))
out(conf_het, "hca_conference_heterogeneity.csv")
e <- list(mu = mu, tau2 = tau2)

cvn <- bind_rows(lapply(2002:2026, function(s) {
  g <- reg %>% filter(season == s); n0 <- 1 - g$neutral
  close <- abs(predict_margin(fit_ratings(g), g$home_id, g$away_id, 1)) < 10
  d <- make_design(g, cbind(conference = n0 * g$conf_game, nonconference = n0 * (1 - g$conf_game)))
  est <- solve_design(d); bt <- boot_design(d, 100)
  d2 <- make_design(g, cbind(conference = n0 * g$conf_game, nonconference = n0 * (1 - g$conf_game) * close, nonconf_mismatch = n0 * (1 - g$conf_game) * (!close)))
  est2 <- solve_design(d2)
  tibble(season = s, season_label = lab_season(s),
         game_type = c("Conference", "Non-conference"), hca = c(est[["conference"]], est[["nonconference"]]),
         ci_low = c(ci(bt[, 1])[1], ci(bt[, 2])[1]), ci_high = c(ci(bt[, 1])[2], ci(bt[, 2])[2]),
         home_games = c(sum(n0 * g$conf_game), sum(n0 * (1 - g$conf_game))),
         hca_nonconf_rating_gap_under_10 = c(NA, est2[["nonconference"]]),
         diff_nonconf_minus_conf = est[["nonconference"]] - est[["conference"]], diff_se = sd(bt[, 2] - bt[, 1]))
}))
out(cvn, "hca_conference_vs_nonconference.csv")
cvn_pool <- cvn %>% filter(game_type == "Non-conference", season != 2021) %>%
  summarise(pooled_diff = sum(diff_nonconf_minus_conf / diff_se^2) / sum(1 / diff_se^2), pooled_se = sqrt(1 / sum(1 / diff_se^2)),
            seasons_nonconf_higher = sum(diff_nonconf_minus_conf > 0), seasons = n())
out(cvn_pool, "hca_conference_vs_nonconference_pooled.csv")

# ---------------------------------------------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------------------------------------------
early_mean <- trend$estimate[1]; late_mean <- trend$estimate[2]
p1d <- by_season %>% mutate(group = case_when(season == 2021 ~ "2020-21 (most arenas empty)",
                                              season < 2008 ~ "Neutral sites rebuilt from venue ids",
                                              TRUE ~ "Neutral sites flagged by ESPN"))
p1 <- ggplot(p1d, aes(season, hca)) +
  geom_line(data = tibble(season = 2002:2026, hca = predict(wls, newdata = tibble(season = 2002:2026))),
            colour = cs_ink[["muted"]], linewidth = 0.8, linetype = "22") +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high, colour = group), width = 0, linewidth = 0.8) +
  geom_point(aes(colour = group, shape = group), size = 2.6, fill = cs_ink[["surface"]], stroke = 1) +
  scale_colour_manual(values = c("Neutral sites flagged by ESPN" = cs_pal[["blue"]], "Neutral sites rebuilt from venue ids" = cs_pal[["blue"]],
                                 "2020-21 (most arenas empty)" = cs_pal[["orange"]])) +
  scale_shape_manual(values = c("Neutral sites flagged by ESPN" = 16, "Neutral sites rebuilt from venue ids" = 21, "2020-21 (most arenas empty)" = 16)) +
  annotate("text", x = 2021.4, y = by_season$hca[by_season$season == 2021] - 0.05, label = "2020-21", hjust = 0, colour = cs_pal[["orange"]], size = 3.6) +
  scale_x_continuous(breaks = seq(2002, 2026, 4), labels = lab_season(seq(2002, 2026, 4))) +
  scale_y_continuous(limits = c(1.8, 5), breaks = seq(2, 5, 0.5)) +
  labs(title = sprintf("Home-court advantage fell from %.1f to %.1f points in 25 seasons", early_mean, late_mean),
       subtitle = "Home edge in points from season-by-season team ratings, D1 vs D1 regular season, with 95% bootstrap intervals.\nDashed line: weighted linear trend, 2020-21 excluded.",
       x = NULL, y = "Home-court advantage (points)",
       caption = sprintf("Source: ESPN via hoopR. %s games, 2001-02 to 2025-26. Early mean = 2001-02 to 2005-06, late mean = 2021-22 to 2025-26.",
                         format(sum(by_season$games), big.mark = ","))) +
  theme_cs()
save_fig(p1, fig("01_hca_by_season.png"), width = 9, height = 5.2)

cvn21 <- cvn %>% filter(season %in% 2019:2023, game_type == "Conference")
lvl <- bind_rows(
  by_season %>% filter(season %in% 2019:2023) %>% transmute(season, row = paste(season_label, "all games"), estimate = hca, ci_low, ci_high),
  cvn21 %>% transmute(season = season + 0.1, row = paste(season_label, "conference games"), estimate = hca, ci_low, ci_high),
  covid %>% filter(spec == "Pooled: empty vs some fans", term %in% c("empty", "fans")) %>%
    transmute(season = 2021.2 + (term == "fans") / 10, row = ifelse(term == "empty", "2020-21 empty arenas", "2020-21 some fans (any)"), estimate, ci_low, ci_high),
  covid %>% filter(spec == "Pooled: crowd size", term == "large") %>% transmute(season = 2021.4, row = "2020-21 1,000+ fans", estimate, ci_low, ci_high)
) %>% arrange(season) %>% mutate(kind = ifelse(floor(season) == 2021, "2020-21", "Other seasons"), panel = "Home-court advantage (points)")
dif <- covid %>% filter(term %in% c("fans_minus_empty", "fans_shift")) %>%
  transmute(row = recode(spec, "Pooled: empty vs some fans" = "Pooled", "Within conference" = "Within conference",
                         "Within home team" = "Within home team", "Within home team, + conference-game and Feb-Mar terms" = "Within team + timing controls"),
            estimate, ci_low, ci_high, kind = "2020-21") %>% mutate(panel = "Some fans minus empty arenas, 2020-21 (points)")
p2d <- bind_rows(lvl, dif) %>% mutate(row = factor(row, levels = rev(c(lvl$row, dif$row))),
                                      panel = factor(panel, levels = c("Home-court advantage (points)", "Some fans minus empty arenas, 2020-21 (points)")))
pooled_gap <- covid %>% filter(spec == "Pooled: empty vs some fans", term == "fans_minus_empty")
team_gap <- covid %>% filter(spec == "Within home team", term == "fans_shift")
p2 <- ggplot(p2d, aes(estimate, row, colour = kind)) +
  geom_vline(data = tibble(panel = factor("Some fans minus empty arenas, 2020-21 (points)", levels = levels(p2d$panel)), x = 0),
             aes(xintercept = x), colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high), orientation = "y", width = 0, linewidth = 0.9) +
  geom_point(size = 2.6) +
  geom_text(aes(label = sprintf("%.1f", estimate)), vjust = -0.8, size = 3.1, show.legend = FALSE) +
  facet_wrap(~ panel, ncol = 1, scales = "free", space = "free_y") +
  scale_y_discrete(expand = expansion(add = c(0.6, 0.9))) +
  scale_colour_manual(values = c("Other seasons" = cs_pal[["blue"]], "2020-21" = cs_pal[["orange"]])) +
  labs(title = sprintf("Empty arenas had a %.1f-point smaller home edge, but only %.1f within the same team",
                       pooled_gap$estimate, team_gap$estimate),
       subtitle = "Top: home edge by season and, for 2020-21, by whether ESPN recorded any attendance. Bottom: the gap when games are\ncompared within the same conference or the same home team. 95% bootstrap intervals.",
       x = "Points", y = NULL,
       caption = sprintf("Source: ESPN via hoopR. 2020-21: %s home games, %s with attendance 0 (median crowd otherwise %s).\nWithin-team rows use the %s home teams that hosted both kinds of game.",
                         format(covid_counts$value[1], big.mark = ","), format(covid_counts$value[2], big.mark = ","),
                         format(covid_counts$value[9], big.mark = ","), covid_counts$value[7])) +
  theme_cs() + theme(legend.position = "none", panel.spacing = unit(14, "pt"), strip.text = element_text(hjust = 0))
save_fig(p2, fig("02_empty_vs_fans_2020_21.png"), width = 9.5, height = 6.8)

m3 <- slopes %>% filter(model == "+ home team-season fixed effects (main)")
pp <- slopes %>% filter(model == "Placebo: same team's previous road game")
pn <- slopes %>% filter(model == "Placebo: same team's next road game")
p3d <- bins %>% mutate(view = factor(view, levels = unique(bins$view)))
p3 <- ggplot(p3d, aes(crowd_vs_usual, home_edge)) +
  geom_hline(yintercept = mean(home$home_edge), colour = cs_ink[["baseline"]], linewidth = 0.6, linetype = "22") +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 0.8, colour = cs_pal[["blue"]]) +
  geom_point(size = 2.4, colour = cs_pal[["blue"]]) +
  facet_wrap(~ view, nrow = 1, scales = "free_x") +
  scale_x_log10(breaks = c(0.6, 0.8, 1, 1.25, 1.6), labels = function(x) paste0(round(100 * x), "%")) +
  labs(title = sprintf("A bigger crowd than usual at the same arena adds no measurable home edge (%+.2f points per doubling)", m3$slope_per_log_unit * log(2)),
       subtitle = "Home edge (margin minus the rating gap) by decile of attendance relative to usual, 95% intervals. Left: raw, where big crowds\ncoincide with strong opponents and conference games. Right: after removing team-season means, opponent gap, conference\ngame, weekend and month.",
       x = "Attendance as a share of the usual crowd (log scale)", y = "Home edge (points)",
       caption = sprintf("Source: ESPN via hoopR. %s home games, %d normal seasons with attendance. Adjusted slope %.2f per log unit (SE %.2f, clustered by venue).\nPlacebos: previous road game %.2f (SE %.2f), next road game %.2f (SE %.2f), so crowds follow recent form.",
                         format(nrow(home), big.mark = ","), length(att_seasons), m3$slope_per_log_unit, m3$se,
                         pp$slope_per_log_unit, pp$se, pn$slope_per_log_unit, pn$se)) +
  theme_cs() + theme(strip.text = element_text(hjust = 0))
save_fig(p3, fig("03_attendance_dose_response.png"), width = 10, height = 5.8)

p4d <- conf_tab %>% mutate(conference = factor(conference, levels = rev(conference)))
p4 <- ggplot(p4d, aes(y = conference)) +
  geom_vline(xintercept = e$mu, colour = cs_ink[["baseline"]], linewidth = 0.6, linetype = "22") +
  geom_errorbar(aes(xmin = shrunk_ci_low, xmax = shrunk_ci_high), orientation = "y", width = 0, colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(aes(x = raw), shape = 21, size = 2, colour = cs_ink[["muted"]], fill = cs_ink[["surface"]], stroke = 0.8) +
  geom_point(aes(x = shrunk), colour = cs_pal[["blue"]], size = 2.4) +
  annotate("text", x = e$mu, y = nrow(p4d) + 0.9, label = sprintf("mean %.1f", e$mu), colour = cs_ink[["secondary"]], size = 3.2, hjust = -0.05) +
  coord_cartesian(ylim = c(1, nrow(p4d) + 1.2), clip = "off") +
  labs(title = sprintf("Conferences differ: true home edges spread about %.1f points around the %.1f mean", sqrt(e$tau2), e$mu),
       subtitle = "Home edge in conference games, 2021-22 to 2025-26 pooled. Blue: shrunk toward the mean\n(random effects), with 95% interval. Hollow: the raw average.",
       x = "Home-court advantage (points)", y = NULL,
       caption = sprintf("Source: ESPN via hoopR. %s conference games. Conferences found as clusters of teams linked by\nconference games and named by an anchor school. Cochran Q = %.0f on %d df.",
                         format(nrow(cg), big.mark = ","), Q, nrow(conf_tab) - 1)) +
  theme_cs()
save_fig(p4, fig("04_hca_by_conference.png"), width = 8.5, height = 8.5)

p5 <- ggplot(cvn, aes(season, hca, colour = game_type, fill = game_type)) +
  geom_ribbon(aes(ymin = ci_low, ymax = ci_high), alpha = 0.15, colour = NA) +
  geom_line(linewidth = 0.9) + geom_point(size = 2) +
  scale_colour_manual(values = c(cs_pal[["blue"]], cs_pal[["orange"]])) +
  scale_fill_manual(values = c(cs_pal[["blue"]], cs_pal[["orange"]])) +
  scale_x_continuous(breaks = seq(2002, 2026, 4), labels = lab_season(seq(2002, 2026, 4))) +
  labs(title = sprintf("Home edge runs %s in non-conference games, in every season",
                       ifelse(cvn_pool$pooled_diff > 0, sprintf("%.1f points larger", cvn_pool$pooled_diff), sprintf("%.1f points smaller", -cvn_pool$pooled_diff))),
       subtitle = "Home-court advantage by season, estimated separately for conference and non-conference home games.\n95% bootstrap bands.",
       x = NULL, y = "Home-court advantage (points)",
       caption = sprintf("Source: ESPN via hoopR, D1 vs D1 regular season. Pooled gap %.2f points (SE %.2f), 2020-21 excluded;\nnon-conference higher in %d of %d seasons.",
                         cvn_pool$pooled_diff, cvn_pool$pooled_se, cvn_pool$seasons_nonconf_higher, cvn_pool$seasons)) +
  theme_cs()
save_fig(p5, fig("05_conference_vs_nonconference.png"), width = 9, height = 5)

cat(sprintf("done in %.1f s\n", as.numeric(difftime(Sys.time(), t_start, units = "secs"))))
