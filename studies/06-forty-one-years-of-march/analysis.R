# Study 06: what 2,644 NCAA tournament games say about seeds, upsets and the 76-team field.
#   A. Seed history, 1985-2026 (seed file from the private pipeline; aggregates only).
#   B. A public-ratings bracket model scored on the 2009-10 to 2025-26 tournaments, against seed history alone.
#   C. The 2026-27 format (76 teams) replayed on the 2026 bracket.
#   Rscript studies/06-forty-one-years-of-march/analysis.R      (from the repo root)
# The seed file: $NCAAB_PRIVATE_ROOT/data/seed/ncaa_tournament_games.csv and data/archive/bracket_2026.csv
# (default: the private pipeline checked out next to this repo's parent folder).
source("R/data.R"); source("R/ratings.R"); source("R/theme.R")
suppressPackageStartupMessages({ library(tidyr); library(readr) })
set.seed(20261105)
dir_s <- "studies/06-forty-one-years-of-march"
fig <- function(name) file.path(dir_s, "figures", name)
res <- function(name) file.path(dir_s, "results", name)
priv <- Sys.getenv("NCAAB_PRIVATE_ROOT", file.path(cs_root(), "..", "..", "ncaab_2027"))
jeffreys <- function(x, n, p) qbeta(p, x + 0.5, n - x + 0.5)
season_label <- function(s) sprintf("%d-%02d", s - 1, s %% 100)

tg <- read_csv(file.path(priv, "data", "seed", "ncaa_tournament_games.csv"), show_col_types = FALSE,
               col_types = cols(game_id = col_character(), region = col_character())) %>%
  mutate(date = as.Date(date))
main_rounds <- c("First Round", "Second Round", "Sweet 16", "Elite 8", "Final Four", "Championship")
cat(sprintf("seed file: %d games, %d tournaments (%d-%d)\n", nrow(tg), n_distinct(tg$season), min(tg$season), max(tg$season)))

# ================================================================================================================
# A. Seed history
# ================================================================================================================
r1 <- tg %>% filter(round == "First Round") %>%
  mutate(fav = pmin(winner_seed, loser_seed), dog = pmax(winner_seed, loser_seed), fav_won = winner_seed < loser_seed,
         pairing = sprintf("%d vs %d", fav, dog))
pairings <- r1 %>% group_by(fav, dog, pairing) %>%
  summarise(games = n(), fav_wins = sum(fav_won), .groups = "drop") %>%
  mutate(dog_wins = games - fav_wins, fav_rate = fav_wins / games,
         ci_low = jeffreys(fav_wins, games, .025), ci_high = jeffreys(fav_wins, games, .975),
         binom_p_vs_half = sapply(seq_along(games), function(i) binom.test(fav_wins[i], games[i], 0.5)$p.value)) %>%
  arrange(fav)
print(pairings)
# 1 vs 16 through 2025 (the 2026 tournament added four more 1-seed wins)
print(r1 %>% filter(fav == 1, season <= 2025) %>% summarise(games = n(), one_seed_wins = sum(fav_won)))

# Upsets by decade. Primary (fixed in advance): First Round, where every year has the same 32 pairings, so the
# rate is comparable across years. All rounds as a check (its mix of pairings depends on earlier upsets).
decade_of <- function(y) case_when(y < 1990 ~ "1985-89", y < 2000 ~ "1990s", y < 2010 ~ "2000s", y < 2020 ~ "2010s", TRUE ~ "2020s")
upsets <- bind_rows(
  r1 %>% transmute(season, scope = "First Round", upset = !fav_won),
  tg %>% filter(round %in% main_rounds, winner_seed != loser_seed) %>% transmute(season, scope = "All rounds", upset = winner_seed > loser_seed)
) %>% mutate(decade = decade_of(season))
by_decade <- upsets %>% group_by(scope, decade) %>%
  summarise(tournaments = n_distinct(season), games = n(), upsets = sum(upset), .groups = "drop") %>%
  mutate(rate = upsets / games, ci_low = jeffreys(upsets, games, .025), ci_high = jeffreys(upsets, games, .975),
         per_tournament = upsets / tournaments)
print(by_decade)
# Trend: logistic regression of a First Round upset on year, with pairing effects; slope per decade.
tr <- glm(!fav_won ~ I((season - 2000) / 10) + factor(pairing), family = binomial, data = r1)
trend <- broom::tidy(tr) %>% filter(grepl("season", term))
tr_all <- glm(upset ~ I((season - 2000) / 10), family = binomial, data = upsets %>% filter(scope == "All rounds"))
trend_all <- broom::tidy(tr_all) %>% filter(grepl("season", term))
decade_test <- chisq.test(table(r1$season %>% decade_of(), !r1$fav_won))
cat(sprintf("First Round upset trend: logit slope per decade %.3f (SE %.3f, p %.2f); decades chi-square p %.2f\n",
            trend$estimate, trend$std.error, trend$p.value, decade_test$p.value))

# Champions and Final Four teams by seed.
champs <- tg %>% filter(round == "Championship") %>% transmute(season, seed = winner_seed)
ff <- tg %>% filter(round == "Final Four") %>% { bind_rows(transmute(., season, seed = winner_seed), transmute(., season, seed = loser_seed)) }
seed_titles <- bind_rows(champs %>% count(seed) %>% mutate(group = "Champions"),
                         ff %>% count(seed) %>% mutate(group = "Final Four teams")) %>%
  group_by(group) %>% mutate(total = sum(n), share = n / total) %>% ungroup() %>%
  complete(group, seed = 1:16, fill = list(n = 0, share = 0)) %>% group_by(group) %>% mutate(total = max(total, na.rm = TRUE)) %>% ungroup() %>%
  filter(seed <= 11)
print(seed_titles %>% filter(n > 0), n = 40)

# ================================================================================================================
# B. Public-ratings bracket model, 2009-10 to 2025-26 (no 2019-20 tournament)
# ================================================================================================================
bracket_order <- c(1, 16, 8, 9, 5, 12, 4, 13, 6, 11, 3, 14, 7, 10, 2, 15)
round_names <- c("Round of 32", "Sweet 16", "Elite 8", "Final Four", "Title game", "Champion")

# Exact advancement probabilities. team_slot: slot 1-64 for each team (two teams share a play-in slot);
# W[i, j] = P(i beats j). Returns an N x 6 matrix: P(team wins its first 1..6 games after any play-in).
bracket_dp <- function(team_slot, W) {
  N <- length(team_slot)
  cur <- rep(1, N)
  for (s in unique(team_slot[duplicated(team_slot)])) {
    ii <- which(team_slot == s)
    cur[ii[1]] <- W[ii[1], ii[2]]; cur[ii[2]] <- W[ii[2], ii[1]]
  }
  out <- matrix(NA_real_, N, 6)
  for (r in 1:6) {
    blk <- (team_slot - 1) %/% 2^r
    half <- ((team_slot - 1) %/% 2^(r - 1)) %% 2
    new <- vapply(seq_len(N), function(i) {
      opp <- which(blk == blk[i] & half != half[i])
      cur[i] * sum(cur[opp] * W[i, opp])
    }, numeric(1))
    cur <- new; out[, r] <- cur
  }
  out
}
win_matrix <- function(rating, sigma) outer(rating, rating, function(a, b) pnorm((a - b) / sigma))

# Team-level field and results for every tournament: 64 teams from the First Round, wins from the First Round on.
# 2020-21: VCU withdrew (COVID protocols) and Oregon advanced without playing, so the 7-10 West game is missing.
field_all <- tg %>% filter(round == "First Round") %>%
  { bind_rows(transmute(., season, region, name = winner, seed = winner_seed, game_id),
              transmute(., season, region, name = loser, seed = loser_seed, game_id)) } %>%
  bind_rows(tibble(season = 2021, region = "West", name = c("Oregon Ducks", "VCU Rams"), seed = c(7, 10), game_id = NA_character_))
wins_all <- tg %>% filter(round %in% main_rounds) %>% transmute(season, name = winner) %>% count(season, name, name = "wins") %>%
  mutate(wins = wins + (season == 2021 & name == "Oregon Ducks"))
field_all <- field_all %>% left_join(wins_all, by = c("season", "name")) %>% mutate(wins = coalesce(wins, 0L))
stopifnot(all(count(field_all, season)$n == 64))

# Seed-only forecasts, leave one season out: P(seed reaches round k) and P(seed a beats seed b).
seed_reach_table <- function(excl) {
  field_all %>% filter(season != excl) %>% group_by(seed) %>%
    summarise(p1 = mean(wins >= 1), p2 = mean(wins >= 2), p3 = mean(wins >= 3),
              p4 = mean(wins >= 4), p5 = mean(wins >= 5), p6 = mean(wins >= 6), .groups = "drop")
}
seed_games <- tg %>% filter(round %in% main_rounds, winner_seed != loser_seed) %>%
  transmute(season, a = pmin(winner_seed, loser_seed), b = pmax(winner_seed, loser_seed), a_won = winner_seed < loser_seed)
seed_pair_prob <- function(excl, a, b) {
  sg <- seed_games %>% filter(season != excl)
  tab <- sg %>% group_by(a, b) %>% summarise(n = n(), w = sum(a_won), .groups = "drop")
  lg <- glm(a_won ~ 0 + I(b - a), family = binomial, data = sg)   # fallback for pairs with < 10 games
  lo <- pmin(a, b); hi <- pmax(a, b)
  t <- tibble(a = lo, b = hi) %>% left_join(tab, by = c("a", "b"))
  p_lo <- ifelse(!is.na(t$n) & t$n >= 10, (t$w + 0.5) / (t$n + 1), predict(lg, newdata = t, type = "response"))
  p_lo[lo == hi] <- 0.5
  ifelse(a == lo, p_lo, 1 - p_lo)                                   # P(the team seeded `a` wins)
}

espn_seasons <- c(2010:2019, 2021:2026)
g_all <- cbb_games(espn_seasons)
# ESPN ids for the seed file's names, through the ESPN game id (names in the seed file follow later renames).
name_ids <- tg %>% filter(round == "First Round", season %in% espn_seasons) %>%
  inner_join(g_all %>% select(game_id, home_id, away_id, home_score, away_score), by = "game_id") %>%
  { bind_rows(transmute(., season, name = winner, team_id = ifelse(home_score > away_score, home_id, away_id)),
              transmute(., season, name = loser, team_id = ifelse(home_score > away_score, away_id, home_id))) } %>%
  bind_rows(g_all %>% filter(season == 2021, home_name %in% c("Oregon Ducks", "VCU Rams")) %>%
              transmute(season, name = home_name, team_id = home_id)) %>%
  distinct()
stopifnot(!anyDuplicated(name_ids[c("season", "name")]))

model_season <- function(s, sig = NULL) {
  gs <- g_all %>% filter(season == s)
  t0 <- tg %>% filter(season == s)
  first_date <- min(t0$date)
  fit <- fit_ratings(gs, before = first_date)
  sg <- if (is.null(sig)) fit$sigma else sig
  fld <- field_all %>% filter(season == s) %>% left_join(name_ids %>% filter(season == s) %>% select(-season), by = "name")
  stopifnot(!anyNA(fld$team_id), nrow(fld) == 64)
  # Final Four pairs: the regions that actually met.
  reg <- setNames(fld$region, fld$name)
  f4 <- t0 %>% filter(round == "Final Four") %>% transmute(r1 = reg[winner], r2 = reg[loser])
  region_order <- c(f4$r1[1], f4$r2[1], f4$r1[2], f4$r2[2])
  stopifnot(setequal(region_order, unique(fld$region)))
  fld <- fld %>% mutate(slot = (match(region, region_order) - 1) * 16 + match(seed, bracket_order))
  r <- setNames(fit$ratings$rating, fit$ratings$team_id)
  fld$rating <- unname(r[fld$team_id])
  stopifnot(!anyNA(fld$rating))
  P <- bracket_dp(fld$slot, win_matrix(fld$rating, sg))
  stopifnot(all(abs(colSums(P) - 64 / 2^(1:6)) < 1e-9))
  sr <- seed_reach_table(s)
  S <- as.matrix(sr[match(fld$seed, sr$seed), paste0("p", 1:6)])
  teams <- bind_cols(fld %>% select(season, region, seed, slot, name, team_id, rating, wins),
                     as_tibble(P, .name_repair = ~ paste0("model_p", 1:6)), as_tibble(S, .name_repair = ~ paste0("seed_p", 1:6)))
  # Game level: every game actually played from the First Round on, scored with pre-tournament ratings.
  # Team a = the better seed (lower id breaks a tie between equal seeds).
  ids <- setNames(fld$team_id, fld$name); sd_ <- setNames(fld$seed, fld$name)
  gm <- t0 %>% filter(round %in% main_rounds) %>%
    mutate(a_is_winner = winner_seed < loser_seed | (winner_seed == loser_seed & ids[winner] < ids[loser]),
           a = ifelse(a_is_winner, winner, loser), b = ifelse(a_is_winner, loser, winner),
           seed_a = sd_[a], seed_b = sd_[b], y = as.integer(a_is_winner),
           margin_a = ifelse(a_is_winner, margin, -margin),
           pred_margin_a = unname(r[ids[a]] - r[ids[b]]),
           model_p = pnorm(pred_margin_a / sg),
           seed_p = seed_pair_prob(s, seed_a, seed_b)) %>%
    select(season, round, seed_a, seed_b, y, margin_a, pred_margin_a, model_p, seed_p)
  list(teams = teams, games = gm, fit = c(season = s, fit_sigma = fit$sigma, sigma_used = sg, hca = fit$hca, n_games = fit$n_games))
}
t0 <- Sys.time()
# Primary: win probabilities use the ratings fit's own sigma. Secondary ("March width"): sigma = SD of the
# tournament margin errors in the other seasons, since the regular-season fit's sigma is in-sample.
ms <- lapply(espn_seasons, model_season)
g0 <- bind_rows(lapply(ms, `[[`, "games"))
sig_loso <- sapply(espn_seasons, function(s) with(g0[g0$season != s, ], sd(margin_a - pred_margin_a)))
ms_w <- mapply(model_season, espn_seasons, sig_loso, SIMPLIFY = FALSE)
cat(sprintf("bracket model: %d tournaments x 2 in %.0f s\n", length(ms), as.numeric(Sys.time() - t0, units = "secs")))
teams <- bind_rows(lapply(ms, `[[`, "teams")) %>%
  bind_cols(bind_rows(lapply(ms_w, `[[`, "teams")) %>% select(starts_with("model_p")) %>% rename_with(~ sub("model_p", "wide_p", .x)))
gms <- g0 %>% mutate(wide_p = bind_rows(lapply(ms_w, `[[`, "games"))$model_p)
fits_tab <- bind_rows(lapply(ms, function(m) as_tibble(as.list(m$fit)))) %>% mutate(sigma_march = sig_loso)

# Round-level Brier: P(team reaches round k) for the 64 teams, vs what happened. Season bootstrap for skill.
long_t <- bind_rows(lapply(1:6, function(k) teams %>% transmute(season, k = k, y = as.integer(wins >= k),
                                                                     model = .data[[paste0("model_p", k)]], wide = .data[[paste0("wide_p", k)]],
                                                                     seed = .data[[paste0("seed_p", k)]])))
brier_tab <- function(x) x %>% group_by(k) %>%
  summarise(n = n(), brier_model = mean((model - y)^2), brier_wide = mean((wide - y)^2), brier_seed = mean((seed - y)^2), .groups = "drop") %>%
  mutate(skill = 1 - brier_model / brier_seed, skill_wide = 1 - brier_wide / brier_seed)
round_brier <- brier_tab(long_t)
by_season_t <- split(long_t, long_t$season)
boot_skill <- replicate(2000, brier_tab(bind_rows(by_season_t[as.character(sample(espn_seasons, replace = TRUE))])) %>% select(skill, skill_wide) %>% as.matrix())
round_brier <- round_brier %>% mutate(round = round_names[k],
                                      skill_low = apply(boot_skill[, 1, ], 1, quantile, .025), skill_high = apply(boot_skill[, 1, ], 1, quantile, .975),
                                      skill_wide_low = apply(boot_skill[, 2, ], 1, quantile, .025), skill_wide_high = apply(boot_skill[, 2, ], 1, quantile, .975),
                                      seasons_model_better = sapply(k, function(kk) {
                                        long_t %>% filter(k == kk) %>% group_by(season) %>%
                                          summarise(b = mean((model - y)^2) < mean((seed - y)^2)) %>% pull(b) %>% sum()
                                      }), n_seasons = length(espn_seasons))
print(round_brier, width = 200)

# Probability given to the eventual champion (log loss is infinite for seed history: UConn won as a 7 seed in
# 2014, and no other 7 seed ever has, so the table without 2014 gives a 7 seed zero chance).
champ_p <- teams %>% filter(wins == 6) %>% summarise(n = n(), model_mean_p = mean(model_p6), wide_mean_p = mean(wide_p6), seed_mean_p = mean(seed_p6),
                                                     seed_zero = sum(seed_p6 == 0))
print(champ_p)

# Game level: Brier, log loss, and reliability.
ll <- function(p, y) -mean(y * log(p) + (1 - y) * log(1 - p))
game_scores <- gms %>% summarise(games = n(), brier_model = mean((model_p - y)^2), brier_wide = mean((wide_p - y)^2), brier_seed = mean((seed_p - y)^2),
                                 logloss_model = ll(model_p, y), logloss_wide = ll(wide_p, y), logloss_seed = ll(seed_p, y),
                                 accuracy_model = mean((model_p > .5) == y), accuracy_seed = mean((seed_p > .5) == y),
                                 margin_slope = coef(lm(margin_a ~ pred_margin_a))[2], resid_sd = sd(margin_a - pred_margin_a))
by_season_g <- split(gms, gms$season)
bg <- replicate(2000, {
  x <- bind_rows(by_season_g[as.character(sample(espn_seasons, replace = TRUE))])
  c(mean((x$seed_p - x$y)^2) - mean((x$model_p - x$y)^2), mean((x$seed_p - x$y)^2) - mean((x$wide_p - x$y)^2))
})
game_scores <- game_scores %>% mutate(brier_gain = brier_seed - brier_model, gain_low = quantile(bg[1, ], .025), gain_high = quantile(bg[1, ], .975),
                                      brier_gain_wide = brier_seed - brier_wide, gain_wide_low = quantile(bg[2, ], .025), gain_wide_high = quantile(bg[2, ], .975),
                                      fit_sigma_mean = mean(fits_tab$fit_sigma), sigma_march_mean = mean(fits_tab$sigma_march))
print(game_scores, width = 250)
fc_levels <- c("Public ratings", "Public ratings, March width", "Seed history")
reliab <- bind_rows(gms %>% transmute(y, p = model_p, forecaster = fc_levels[1]),
                    gms %>% transmute(y, p = wide_p, forecaster = fc_levels[2]),
                    gms %>% transmute(y, p = seed_p, forecaster = fc_levels[3])) %>%
  mutate(bin = cut(p, breaks = seq(0, 1, 0.1), include.lowest = TRUE)) %>%
  group_by(forecaster, bin) %>%
  summarise(games = n(), mean_forecast = mean(p), wins = sum(y), observed = mean(y), .groups = "drop") %>%
  mutate(ci_low = jeffreys(wins, games, .025), ci_high = jeffreys(wins, games, .975))

# ================================================================================================================
# C. The 76-team field, replayed on the 2026 bracket
# ================================================================================================================
b26 <- read_csv(file.path(priv, "data", "archive", "bracket_2026.csv"), show_col_types = FALSE,
                col_types = cols(team_id = col_character())) %>%
  select(team_id, team_name, seed, region, play_in)                 # bracket only; no licensed columns
g26 <- cbb_games(2026)
first26 <- min(tg$date[tg$season == 2026])                         # 2026-03-17: ratings use every game through Selection Sunday
fit26 <- fit_ratings(g26, before = first26)
r26 <- setNames(fit26$ratings$rating, fit26$ratings$team_id)
names26 <- g26 %>% { bind_rows(transmute(., team_id = home_id, name = home_name), transmute(., team_id = away_id, name = away_name)) } %>% distinct(team_id, .keep_all = TRUE)
f4_26 <- tg %>% filter(season == 2026, round == "Final Four")
reg26 <- setNames(field_all$region[field_all$season == 2026], field_all$name[field_all$season == 2026])
region_order26 <- c(reg26[f4_26$winner[1]], reg26[f4_26$loser[1]], reg26[f4_26$winner[2]], reg26[f4_26$loser[2]])
b26 <- b26 %>% mutate(rating = unname(r26[team_id]), slot = (match(region, region_order26) - 1) * 16 + match(seed, bracket_order), added = FALSE)
stopifnot(!anyNA(b26$rating), nrow(b26) == 68, sum(duplicated(b26$slot)) == 4)

added <- fit26$ratings %>% filter(!team_id %in% b26$team_id) %>% arrange(desc(rating)) %>% head(8) %>%
  left_join(names26, by = "team_id")
# Candidate slots: the 10-, 11- and 12-seed slots that a single team holds (the two shared 11-seed slots are
# already play-ins). The 8 held by the lowest-rated teams each get an added team; strongest added team meets the
# strongest of those 8 holders, and so on down.
cand <- b26 %>% filter(seed %in% 10:12, play_in == 0) %>% arrange(rating)
hold <- cand %>% head(8) %>% arrange(desc(rating))
build76 <- function(hold_slots) {
  bind_rows(b26, tibble(team_id = added$team_id, team_name = added$name, seed = b26$seed[match(hold_slots, b26$slot)],
                        region = b26$region[match(hold_slots, b26$slot)], play_in = 1, rating = added$rating, slot = hold_slots, added = TRUE))
}
b76 <- build76(hold$slot)
b68 <- b26
stopifnot(nrow(b76) == 76, sum(duplicated(b76$slot)) == 12)

title_tab <- function(b, rating = b$rating, sigma = fit26$sigma) {
  P <- bracket_dp(b$slot, win_matrix(rating, sigma))
  tibble(team_id = b$team_id, p_r32 = P[, 1], p_s16 = P[, 2], p_f4 = P[, 4], p_title = P[, 6])
}
t68 <- title_tab(b68); t76 <- title_tab(b76)
added_title <- sum(t76$p_title[b76$added])
added_title_wide <- sum(title_tab(b76, sigma = mean(sig_loso))$p_title[b76$added])

# Rating uncertainty: 200 game-level bootstrap refits of the 2026 ratings (field and added teams held fixed).
pre26 <- g26 %>% filter(date < first26)
boot26 <- replicate(200, {
  f <- fit_ratings(pre26[sample(nrow(pre26), replace = TRUE), ], before = first26)
  rr <- setNames(f$ratings$rating, f$ratings$team_id)
  a <- title_tab(b68, unname(rr[b68$team_id]), f$sigma); z <- title_tab(b76, unname(rr[b76$team_id]), f$sigma)
  c(added = sum(z$p_title[b76$added]), z$p_title[1:68] - a$p_title)
})
# Slot sensitivity: 200 random placements of the 8 added teams among the 10 candidate slots.
slot_sens <- replicate(200, { z <- title_tab(build76(sample(cand$slot, 8))); sum(z$p_title[77 - 8:1]) })

top <- b68 %>% mutate(i = row_number()) %>% filter(seed <= 4) %>%
  transmute(team_id, team = team_name, seed, region, rating,
            title_prob_68 = t68$p_title[i], title_prob_76 = t76$p_title[i], change = title_prob_76 - title_prob_68,
            change_low = apply(boot26[-1, , drop = FALSE][i, , drop = FALSE], 1, quantile, .05),
            change_high = apply(boot26[-1, , drop = FALSE][i, , drop = FALSE], 1, quantile, .95)) %>%
  arrange(seed, desc(title_prob_68))
print(top, n = 20, width = 200)

# Monte Carlo, 100,000 tournaments per format: upsets and a check on the exact probabilities.
simulate <- function(b, nsim = 1e5, sigma = fit26$sigma) {
  W <- win_matrix(b$rating, sigma)
  seeds <- b$seed; rt <- b$rating
  up_seed <- up_rating <- numeric(nsim)
  tally <- function(w, l) {
    up_seed <<- up_seed + rowSums(matrix(seeds[w] > seeds[l], nsim))
    up_rating <<- up_rating + rowSums(matrix(rt[w] < rt[l], nsim))
  }
  occ <- matrix(NA_integer_, nsim, 64)
  for (s in 1:64) {
    ii <- which(b$slot == s)
    if (length(ii) == 1) { occ[, s] <- ii; next }
    aw <- runif(nsim) < W[ii[1], ii[2]]
    occ[, s] <- ifelse(aw, ii[1], ii[2]); tally(occ[, s], ifelse(aw, ii[2], ii[1]))
  }
  cur <- occ
  while (ncol(cur) > 1) {
    a <- as.vector(cur[, c(TRUE, FALSE)]); z <- as.vector(cur[, c(FALSE, TRUE)])
    aw <- runif(length(a)) < W[cbind(a, z)]
    w <- ifelse(aw, a, z); tally(w, ifelse(aw, z, a))
    cur <- matrix(w, nsim)
  }
  list(champ = cur[, 1], up_seed = up_seed, up_rating = up_rating)
}
s68 <- simulate(b68); s76 <- simulate(b76)
s68w <- simulate(b68, sigma = mean(sig_loso)); s76w <- simulate(b76, sigma = mean(sig_loso))
mc_check <- max(abs(tabulate(s76$champ, 76) / 1e5 - t76$p_title))
sims <- list(s68, s76, s68w, s76w)
# Seed upsets per tournament that actually happened, 2009-10 to 2025-26 (First Round on), for scale.
hist_seed_upsets <- upsets %>% filter(scope == "All rounds", season >= 2010) %>% group_by(season) %>% summarise(n = sum(upset))
upset_tab <- tibble(format = c("68 teams (2026)", "76 teams (2026-27 rules)", "68 teams, March width", "76 teams, March width"),
                    sigma = c(fit26$sigma, fit26$sigma, mean(sig_loso), mean(sig_loso)), games = c(67, 75, 67, 75),
                    seed_upsets_mean = sapply(sims, function(x) mean(x$up_seed)),
                    seed_upsets_sd = sapply(sims, function(x) sd(x$up_seed)),
                    rating_upsets_mean = sapply(sims, function(x) mean(x$up_rating)),
                    rating_upsets_sd = sapply(sims, function(x) sd(x$up_rating)),
                    added_team_title_share = sapply(sims, function(x) mean(x$champ > 68)), sims = 1e5) %>%
  bind_rows(tibble(format = "Actual, 2009-10 to 2025-26 (per tournament, First Round on)", games = 63,
                   seed_upsets_mean = mean(hist_seed_upsets$n), seed_upsets_sd = sd(hist_seed_upsets$n), sims = nrow(hist_seed_upsets)))
# Check on the upset count itself: what the model expected in each backtest bracket (64 teams, actual field)
# vs what happened. A model that is too sure of the favorites expects too few upsets.
upset_check <- bind_rows(lapply(seq_along(espn_seasons), function(i) {
  b <- teams %>% filter(season == espn_seasons[i]) %>% select(slot, seed, rating)
  tibble(season = espn_seasons[i], actual = hist_seed_upsets$n[hist_seed_upsets$season == espn_seasons[i]],
         expected_fit_sigma = mean(simulate(b, 2e4, fits_tab$fit_sigma[i])$up_seed),
         expected_march_sigma = mean(simulate(b, 2e4, sig_loso[i])$up_seed))
}))
upset_tab <- upset_tab %>%
  bind_rows(tibble(format = c("Backtest brackets, model expected (fit sigma)", "Backtest brackets, model expected (March width)"),
                   games = 63, seed_upsets_mean = c(mean(upset_check$expected_fit_sigma), mean(upset_check$expected_march_sigma)),
                   sims = 2e4))
print(upset_tab, width = 200)
upset_check_all <- upset_check %>% summarise(gap_fit_se = sd(actual - expected_fit_sigma) / sqrt(n()),
                                             gap_march_se = sd(actual - expected_march_sigma) / sqrt(n()), across(-season, mean))
print(upset_check_all)
c76 <- tibble(stat = c("added_title_prob_exact", "added_title_prob_march_sigma", "added_title_prob_boot_p05", "added_title_prob_boot_p95",
                       "added_title_prob_slot_min", "added_title_prob_slot_max", "added_sweet16_expected", "added_final_four_expected",
                       "extra_rating_upsets", "extra_rating_upsets_se", "extra_seed_upsets", "extra_seed_upsets_se",
                       "mc_max_abs_error_title_prob", "sigma", "hca"),
              value = c(added_title, added_title_wide, quantile(boot26[1, ], .05), quantile(boot26[1, ], .95), min(slot_sens), max(slot_sens),
                        sum(t76$p_s16[b76$added]), sum(t76$p_f4[b76$added]),
                        mean(s76$up_rating) - mean(s68$up_rating), sqrt((var(s76$up_rating) + var(s68$up_rating)) / 1e5),
                        mean(s76$up_seed) - mean(s68$up_seed), sqrt((var(s76$up_seed) + var(s68$up_seed)) / 1e5),
                        mc_check, fit26$sigma, fit26$hca))
print(c76)
holders <- b76 %>% filter(!added)
added_tab <- b76 %>% mutate(i = row_number()) %>% filter(added) %>%
  transmute(team = team_name, rating, seed, region,
            opponent = holders$team_name[match(slot, holders$slot)], opponent_rating = holders$rating[match(slot, holders$slot)],
            p_win_play_in = pnorm((rating - opponent_rating) / fit26$sigma), p_s16 = t76$p_s16[i], p_title = t76$p_title[i])
print(added_tab, width = 200)

# ================================================================================================================
# Results
# ================================================================================================================
write_csv(pairings, res("first_round_pairings.csv"))
write_csv(by_decade %>% bind_rows(tibble(scope = "First Round trend", decade = "logit slope per decade",
                                         rate = trend$estimate, ci_low = trend$estimate - 1.96 * trend$std.error,
                                         ci_high = trend$estimate + 1.96 * trend$std.error),
                                  tibble(scope = "All rounds trend", decade = "logit slope per decade",
                                         rate = trend_all$estimate, ci_low = trend_all$estimate - 1.96 * trend_all$std.error,
                                         ci_high = trend_all$estimate + 1.96 * trend_all$std.error)),
          res("upsets_by_decade.csv"))
write_csv(seed_titles, res("champion_final_four_seeds.csv"))
write_csv(round_brier, res("round_brier.csv"))
write_csv(bind_cols(game_scores, champ_p %>% rename_with(~ paste0("champion_", .x))), res("game_scores.csv"))
write_csv(fits_tab, res("rating_fits.csv"))
write_csv(reliab, res("reliability.csv"))
write_csv(teams %>% group_by(seed) %>% summarise(across(c(starts_with("model_p"), starts_with("wide_p"), starts_with("seed_p")), mean),
                                                 actual_mean_wins = mean(wins), teams = n()),
          res("advancement_by_seed.csv"))
write_csv(top, res("top_seed_title_prob.csv"))
write_csv(upset_tab, res("upsets_68_vs_76.csv"))
write_csv(bind_rows(upset_check %>% mutate(season = as.character(season)), upset_check_all %>% mutate(season = "mean")), res("upset_count_check.csv"))
write_csv(c76, res("field76_summary.csv"))
write_csv(added_tab, res("field76_added_teams.csv"))

# ================================================================================================================
# Figures
# ================================================================================================================
p1d <- pairings %>% mutate(pairing = factor(pairing, levels = rev(pairing)),
                           txt = sprintf("%d-%d  (%.0f%%)", fav_wins, dog_wins, 100 * fav_rate))
p1 <- ggplot(p1d, aes(x = fav_rate, y = pairing)) +
  geom_vline(xintercept = 0.5, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high), width = 0, orientation = "y", linewidth = 0.9, colour = cs_pal[["blue"]]) +
  geom_point(size = 2.8, colour = cs_pal[["blue"]]) +
  geom_text(aes(x = pmin(ci_high, 1) , label = txt), hjust = -0.12, size = 3.3, colour = cs_ink[["secondary"]]) +
  scale_x_continuous(labels = scales::percent, limits = c(0.35, 1.17), breaks = seq(0.4, 1, 0.1)) +
  labs(title = "Seeds hold up in the First Round, except 8 vs 9, which is a coin flip",
       subtitle = "Better seed's First Round win rate by pairing, 1985-2026 (Jeffreys 95% interval; label = record)",
       x = "Better seed's win rate", y = NULL,
       caption = sprintf("%s First Round games, 41 tournaments (none in 2020). 2009 on from ESPN; 1985-2008 from Sports Reference brackets.",
                         format(sum(pairings$games), big.mark = ","))) +
  theme_cs()
save_fig(p1, fig("01_first_round_pairings.png"), width = 8.5, height = 5)

p2d <- by_decade %>% mutate(decade = factor(decade, levels = c("1985-89", "1990s", "2000s", "2010s", "2020s")),
                            scope = factor(scope, levels = c("First Round", "All rounds")))
p2 <- ggplot(p2d, aes(x = decade, y = rate, colour = scope)) +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 0.9, position = position_dodge(width = 0.45)) +
  geom_point(size = 2.8, position = position_dodge(width = 0.45)) +
  scale_colour_manual(values = unname(cs_pal[c("blue", "orange")])) +
  scale_y_continuous(labels = scales::percent, limits = c(0.1, 0.4)) +
  labs(title = "March is not measurably more chaotic: upset rates show no clear trend since 1985",
       subtitle = "Share of games won by the worse seed, by decade (Jeffreys 95% interval)",
       x = NULL, y = "Upset rate",
       caption = sprintf("First Round: %s games (the same 32 pairings every year). All rounds: %s games between different seeds. 1985-2026; 2020s = 2021-2026.",
                         format(sum(p2d$games[p2d$scope == "First Round"]), big.mark = ","), format(sum(p2d$games[p2d$scope == "All rounds"]), big.mark = ","))) +
  theme_cs()
save_fig(p2, fig("02_upsets_by_decade.png"), width = 8, height = 4.8)

p3 <- ggplot(seed_titles, aes(x = factor(seed), y = n)) +
  geom_col(fill = cs_pal[["blue"]], width = 0.7) +
  geom_text(aes(label = ifelse(n > 0, n, "")), vjust = -0.4, size = 3.2, colour = cs_ink[["secondary"]]) +
  facet_wrap(~ group, scales = "free_y", ncol = 2) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(title = sprintf("%d of 41 champions were 1 seeds; no champion was seeded worse than 8", sum(champs$seed == 1)),
       subtitle = "Champions and Final Four teams by seed, 1985-2026 (seeds 12-16: no Final Four team)",
       x = "Seed", y = "Teams",
       caption = "41 tournaments, 164 Final Four teams. Seeds 1-11 shown.") +
  theme_cs()
save_fig(p3, fig("03_champion_seeds.png"), width = 8.5, height = 4.6)

p4d <- reliab %>% mutate(forecaster = factor(forecaster, levels = fc_levels))
p4 <- ggplot(p4d, aes(x = mean_forecast, y = observed)) +
  geom_abline(slope = 1, intercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 0.8, colour = cs_pal[["blue"]]) +
  geom_line(linewidth = 0.8, colour = cs_pal[["blue"]]) +
  geom_point(size = 2.2, colour = cs_pal[["blue"]]) +
  facet_wrap(~ forecaster, ncol = 3) +
  scale_x_continuous(labels = scales::percent, limits = c(0, 1), breaks = c(0, .5, 1)) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  coord_equal() +
  labs(title = "Ratings are slightly overconfident in March; a wider error band fixes it",
       subtitle = "Forecast vs actual win rate for the better seed, games grouped in 10-point bins (95% interval)",
       x = "Forecast win probability", y = "Actual win rate",
       caption = sprintf("%s tournament games, 2009-10 to 2025-26. Ratings fit on games before each tournament. March width: sigma from the\nother seasons' tournament games. Seed history excludes the season being scored.", format(nrow(gms), big.mark = ","))) +
  theme_cs() + theme(panel.spacing.x = unit(1.4, "lines"))
save_fig(p4, fig("04_reliability.png"), width = 9.5, height = 4.6)

p5d <- round_brier %>% mutate(round = factor(round, levels = round_names))
p5 <- ggplot(p5d, aes(x = round, y = skill)) +
  geom_hline(yintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(ymin = skill_low, ymax = skill_high), width = 0, linewidth = 0.9, colour = cs_pal[["blue"]]) +
  geom_point(size = 3, colour = cs_pal[["blue"]]) +
  geom_text(aes(label = sprintf("%+.1f%%\n(%d of %d)", 100 * skill, seasons_model_better, n_seasons)), nudge_x = 0.32, size = 3,
            colour = cs_ink[["secondary"]]) +
  scale_y_continuous(labels = scales::percent) +
  labs(title = "Ratings add a little over seed history in the early rounds, and nothing for the champion",
       subtitle = "Brier skill of public ratings vs seed history, P(team reaches each round) (95% season-bootstrap interval)",
       x = NULL, y = "Brier skill vs seed history",
       caption = sprintf("1,024 teams (64 x 16 tournaments, 2009-10 to 2025-26). Label: skill, and seasons in which ratings scored better.")) +
  theme_cs()
save_fig(p5, fig("05_skill_by_round.png"), width = 8.5, height = 4.8)

p6d <- top %>% filter(seed <= 2) %>% mutate(lbl = sprintf("%s (%d, %s)", team, seed, region),
                                            lbl = factor(lbl, levels = rev(lbl)))
p6 <- ggplot(p6d, aes(x = 100 * change, y = lbl)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.6) +
  geom_errorbar(aes(xmin = 100 * change_low, xmax = 100 * change_high), width = 0, orientation = "y", linewidth = 0.9, colour = cs_pal[["blue"]]) +
  geom_point(size = 2.8, colour = cs_pal[["blue"]]) +
  geom_text(aes(x = 100 * change_high, label = sprintf("%.1f%% -> %.1f%%", 100 * title_prob_68, 100 * title_prob_76)),
            hjust = -0.12, size = 3.1, colour = cs_ink[["secondary"]]) +
  scale_x_continuous(expand = expansion(mult = c(0.08, 0.35))) +
  labs(title = "Eight more teams barely change the favorites' title chances",
       subtitle = "Change in title probability, 76-team vs 68-team field, 2026 bracket (points; 90% rating-bootstrap interval)",
       x = "Change in title probability (percentage points)", y = NULL,
       caption = "Public ratings through Selection Sunday 2026; 8 best-rated teams left out added as play-in teams on the 10-12 lines. Label: 68 -> 76.") +
  theme_cs()
save_fig(p6, fig("06_title_prob_change.png"), width = 8.5, height = 4.6)
cat("done\n")
