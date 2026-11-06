# 07. Team archetypes: what kinds of teams are there, and does style matter in March once you account for quality?
#   Rscript studies/07-team-archetypes/analysis.R      (from the repo root; public ESPN data via hoopR, warm cache)
#
# Design
#   Unit: D1 team-season, 2007-08 to 2025-26, regular-season D1-vs-D1 games before the NCAA tournament (>= 10 games).
#   Style (clustered): tempo, and on each end 3PA rate, offensive rebound %, FT rate, turnover %.
#   Quality (never clustered): ridge rating from fit_ratings, raw efficiency margin, eFG% on both ends.
#   Each style feature is regressed on the team's rating within its season and the residual is z-scored within season,
#   so a cluster says how a team plays relative to teams of similar quality in the same year. Raw z-scores are a check.
#   k-means for k = 2..8, average silhouette (vs. a no-cluster Gaussian null) and bootstrap stability (pairwise ARI).
#
# March comparison, fixed before any tournament result was computed (only regular-season data had been looked at):
#   Teams: NCAA tournament teams 2009-10 to 2025-26 (ESPN tournament_id 22; 16 tournaments, none in 2020).
#   Expectation: P(win) = pnorm(predicted margin / sigma), fit_ratings on that season's games before the first
#     tournament game; ratings are not updated during the tournament.
#   Outcome: wins above expectation (WAE) per team-tournament = sum over its games of (win - P(win)), First Four included.
#   Primary test: one global permutation test (labels shuffled within season, 10,000 draws) of the between-archetype
#     sum of squares of WAE. Archetype means get 95% CIs from a cluster bootstrap over tournaments.
#   Checks, all reported whatever they show: raw-feature archetypes, leave-one-tournament-out recalibrated sigma,
#     First Four excluded, WAE residualized on pre-tournament rating.
source("R/data.R"); source("R/ratings.R"); source("R/theme.R")
suppressPackageStartupMessages({ library(tidyr); library(cluster) })
t0 <- Sys.time()
study <- "studies/07-team-archetypes"
fig <- function(f) file.path(study, "figures", f)
res <- function(f) file.path(study, "results", f)
dir.create(file.path(study, "results"), recursive = TRUE, showWarnings = FALSE)
write_res <- function(x, f) write.csv(x, res(f), row.names = FALSE)
set.seed(20261105)

seasons <- 2008:2026
g  <- cbb_games(seasons)
tb <- cbb_team_box(seasons)
team_names <- bind_rows(g %>% select(season, team_id = home_id, team = home_name),
                        g %>% select(season, team_id = away_id, team = away_name)) %>%
  distinct(season, team_id, .keep_all = TRUE)

# NCAA tournament games. ESPN's tournament_id 22 matches the 2009-10 to 2025-26 bracket game list exactly, except two
# 2016-17 First Four games that ESPN's public file lacks.
ncaa <- g %>% filter(season_type == 3, tournament_id == "22")
cutoff <- tibble(season = seasons) %>%
  left_join(ncaa %>% group_by(season) %>% summarise(start = min(date)), by = "season") %>%
  mutate(cut = coalesce(start, as.Date(sprintf("%d-07-01", season))))

# ---- 1. Team-season features -----------------------------------------------------------------------------------
rs <- g %>% inner_join(cutoff, by = "season") %>%
  filter(season_type == 2, home_d1, away_d1, date < cut) %>% select(game_id, ot_periods)
b <- tb %>% filter(season_type == 2) %>% inner_join(rs, by = "game_id")
opp <- b %>% select(game_id, opp_id = team_id, o_fgm = fgm, o_fga = fga, o_fg3m = fg3m, o_fg3a = fg3a, o_fta = fta,
                    o_orb = orb, o_drb = drb, o_tov = tov, o_poss = poss, o_pts = pts)
bb <- b %>% inner_join(opp, by = c("game_id", "opp_id"))
n_bad <- sum(abs(bb$poss - bb$o_poss) > 10)   # box-score errors: the two teams' possession counts disagree by > 10
bb <- bb %>% filter(abs(poss - o_poss) <= 10)

ts <- bb %>% group_by(season, team_id) %>% summarise(
  n_games = n(),
  pace_poss = sum((poss + o_poss) / 2), minutes = sum(40 + 5 * ot_periods),
  tempo = 40 * pace_poss / minutes,
  off_3par = sum(fg3a) / sum(fga), off_orb = sum(orb) / (sum(orb) + sum(o_drb)),
  off_ftr = sum(fta) / sum(fga), off_tov = sum(tov) / sum(poss),
  def_3par = sum(o_fg3a) / sum(o_fga), def_orb = sum(o_orb) / (sum(o_orb) + sum(drb)),
  def_ftr = sum(o_fta) / sum(o_fga), def_tov = sum(o_tov) / sum(o_poss),
  off_efg = (sum(fgm) + 0.5 * sum(fg3m)) / sum(fga), def_efg = (sum(o_fgm) + 0.5 * sum(o_fg3m)) / sum(o_fga),
  net_eff = 100 * (sum(pts) - sum(o_pts)) / pace_poss, .groups = "drop") %>%
  filter(n_games >= 10)

fits <- setNames(lapply(seasons, function(s) fit_ratings(g %>% filter(season == s), before = cutoff$cut[cutoff$season == s])),
                 seasons)
ratings <- bind_rows(lapply(names(fits), function(s) fits[[s]]$ratings %>% mutate(season = as.integer(s))))
ts <- ts %>% inner_join(ratings %>% select(season, team_id, rating), by = c("season", "team_id")) %>%
  left_join(team_names, by = c("season", "team_id")) %>% arrange(season, team_id)

style <- c("tempo", "off_3par", "off_orb", "off_ftr", "off_tov", "def_3par", "def_orb", "def_ftr", "def_tov")
style_lab <- c(tempo = "Tempo", off_3par = "3PA rate", off_orb = "Off. rebound %", off_ftr = "FT rate",
               off_tov = "Turnover %", def_3par = "Opp. 3PA rate", def_orb = "Opp. off. rebound %",
               def_ftr = "Opp. FT rate", def_tov = "Opp. turnover %")
zs <- function(x) (x - mean(x)) / sd(x)
Z_res  <- ts %>% group_by(season) %>% mutate(across(all_of(style), ~ zs(residuals(lm(.x ~ rating))))) %>% ungroup()
Z_raw  <- ts %>% group_by(season) %>% mutate(across(all_of(style), zs)) %>% ungroup()
Z_pool <- ts %>% mutate(across(all_of(style), zs))          # pooled across seasons: used only to show the era problem
X <- as.matrix(Z_res[, style])
quality_cor <- sapply(style, function(f) cor(Z_raw[[f]], Z_raw$rating))
cat(sprintf("team-seasons %d (%d box rows dropped); |r| with rating: %s\n", nrow(ts), n_bad,
            paste(sprintf("%s %.2f", names(quality_cor), quality_cor), collapse = ", ")))

# ---- 2. League-wide trends (raw) ----------------------------------------------------------------------------------
lg <- bb %>% group_by(season) %>%
  summarise(off_3par = sum(fg3a) / sum(fga), tempo = 40 * sum((poss + o_poss) / 2) / sum(40 + 5 * ot_periods))
trend <- ts %>% select(season, tempo, off_3par) %>% pivot_longer(-season, names_to = "metric") %>%
  group_by(season, metric) %>%
  summarise(team_p25 = quantile(value, 0.25), team_median = median(value), team_p75 = quantile(value, 0.75),
            n_teams = n(), .groups = "drop") %>%
  left_join(lg %>% pivot_longer(-season, names_to = "metric", values_to = "d1_pooled"), by = c("season", "metric"))
write_res(trend, "league_trends.csv")
tr <- function(m, s) trend$d1_pooled[trend$metric == m & trend$season == s]
mlab <- c(off_3par = "Share of shots from three (3PA / FGA)", tempo = "Possessions per 40 minutes")
p1 <- ggplot(trend %>% mutate(metric = factor(mlab[metric], mlab)), aes(season)) +
  geom_ribbon(aes(ymin = team_p25, ymax = team_p75), fill = cs_pal[["blue"]], alpha = 0.15) +
  geom_line(aes(y = d1_pooled), colour = cs_pal[["blue"]], linewidth = 0.9) +
  geom_point(aes(y = d1_pooled), colour = cs_pal[["blue"]], size = 2) +
  geom_vline(data = tibble(metric = factor(mlab[["tempo"]], mlab)), aes(xintercept = 2015.5),
             colour = cs_ink[["muted"]], linetype = "dashed") +
  geom_text(data = tibble(metric = factor(mlab[["tempo"]], mlab)), aes(x = 2015.7, y = 71.6, label = "Shot clock\n35 -> 30 s"),
            hjust = 0, vjust = 1, size = 3, colour = cs_ink[["secondary"]], lineheight = 0.9) +
  facet_wrap(~metric, scales = "free_y") +
  scale_y_continuous(labels = function(y) ifelse(y < 1, scales::percent(y, accuracy = 1), y)) +
  scale_x_continuous(breaks = c(2008, 2012, 2016, 2020, 2024), labels = function(x) sprintf("%d-%02d", x - 1, x %% 100)) +
  labs(title = sprintf("Threes rose from %.0f%% to %.0f%% of shots; pace moved once, with the 2015-16 shot clock",
                       100 * tr("off_3par", 2008), 100 * tr("off_3par", 2026)),
       subtitle = "D1 regular season, all D1-vs-D1 games pooled (line); band = middle half of teams",
       x = NULL, y = NULL,
       caption = sprintf("Source: ESPN box scores via hoopR. %s team-seasons, %s team-games.",
                         format(nrow(ts), big.mark = ","), format(nrow(bb), big.mark = ","))) +
  theme_cs()
save_fig(p1, fig("01_league_trends.png"), width = 9, height = 4.6)

# ---- 3. Choosing k: silhouette vs. a no-cluster null, and bootstrap stability -----------------------------------
ari <- function(a, b) {
  tab <- table(a, b)
  sc <- sum(choose(tab, 2)); sa <- sum(choose(rowSums(tab), 2)); sb <- sum(choose(colSums(tab), 2))
  e <- sa * sb / choose(sum(tab), 2)
  (sc - e) / ((sa + sb) / 2 - e)
}
stopifnot(abs(ari(c(1, 1, 2, 2, 3), c(2, 2, 1, 1, 3)) - 1) < 1e-12)
nearest <- function(x, centers) max.col(-sapply(seq_len(nrow(centers)), function(j) colSums((t(x) - centers[j, ])^2)))
km <- function(x, k, nstart) suppressWarnings(kmeans(x, k, nstart = nstart, iter.max = 100))
# Gaussian null: same n and same correlation matrix, but no cluster structure at all.
Xnull <- matrix(rnorm(length(X)), nrow(X)) %*% chol(cov(X))
D <- dist(X); Dnull <- dist(Xnull)
B_stab <- 40
ksel <- bind_rows(lapply(2:8, function(k) {
  f <- km(X, k, 25)
  boots <- sapply(seq_len(B_stab), function(i) nearest(X, km(X[sample(nrow(X), replace = TRUE), ], k, 10)$centers))
  a <- apply(combn(B_stab, 2), 2, function(p) ari(boots[, p[1]], boots[, p[2]]))
  tibble(k = k, silhouette = mean(silhouette(f$cluster, D)[, 3]),
         null_silhouette = mean(silhouette(km(Xnull, k, 25)$cluster, Dnull)[, 3]),
         ari_mean = mean(a), ari_p05 = unname(quantile(a, 0.05)), smallest_cluster_share = min(f$size) / nrow(X))
}))
rm(D, Dnull)
# Silhouette is weak at every k (< 0.25, "no substantial structure"), so it cannot pick k on its own. Rule: the largest
# k whose bootstrap fits agree (mean pairwise ARI >= 0.80). Set after seeing the silhouettes, before any March data.
k_star <- max(ksel$k[ksel$ari_mean >= 0.80])
write_res(ksel %>% mutate(chosen = k == k_star), "k_selection.csv")
cat(sprintf("k chosen: %d\n", k_star)); print(as.data.frame(ksel), digits = 3)
p2 <- ksel %>%
  transmute(k, `Average silhouette: real data` = silhouette, `Average silhouette: no-cluster null` = null_silhouette,
            `Bootstrap agreement (mean ARI)` = ari_mean) %>%
  pivot_longer(-k) %>%
  mutate(panel = ifelse(grepl("silhouette", name), "Average silhouette (higher = better separated)",
                        "Bootstrap agreement between refits (ARI)"),
         series = factor(ifelse(grepl("null", name), "No-cluster Gaussian null", "Real team-seasons"),
                         c("Real team-seasons", "No-cluster Gaussian null"))) %>%
  ggplot(aes(k, value, colour = series)) +
  geom_vline(xintercept = k_star, colour = cs_ink[["baseline"]], linetype = "dashed") +
  geom_line(linewidth = 0.9) + geom_point(size = 2.2) +
  facet_wrap(~panel, scales = "free_y") +
  scale_colour_manual(values = c("Real team-seasons" = cs_pal[["blue"]], "No-cluster Gaussian null" = cs_pal[["orange"]])) +
  scale_x_continuous(breaks = 2:8) +
  labs(title = sprintf("Style has no natural clusters; %d groups is the most that refits reproduce", k_star),
       subtitle = "k-means on 9 quality-adjusted style features. Dashed line = chosen k (largest k with mean ARI >= 0.80)",
       x = "Number of clusters (k)", y = NULL,
       caption = sprintf("Null: Gaussian draws with the real data's correlations. ARI over %d bootstrap refits (%d pairs). n = %s team-seasons.",
                         B_stab, choose(B_stab, 2), format(nrow(X), big.mark = ","))) +
  theme_cs()
save_fig(p2, fig("02_k_selection.png"), width = 9, height = 4.6)

# ---- 4. Final archetypes and names --------------------------------------------------------------------------------
fit_k <- km(X, k_star, 100)
templates <- rbind(   # sign patterns read off the centroids; matched to clusters by the best of all 4! assignments
  "Pace and space"           = c(tempo =  1, off_3par =  1, off_orb = -1, off_ftr =  0, off_tov = -1, def_3par = 0, def_orb =  1, def_ftr =  0, def_tov =  0),
  "Slow and perimeter"       = c(tempo = -1, off_3par =  1, off_orb = -1, off_ftr = -1, off_tov =  0, def_3par = 0, def_orb = -1, def_ftr =  0, def_tov =  0),
  "Pressure and glass"       = c(tempo =  0, off_3par =  0, off_orb =  1, off_ftr =  1, off_tov =  1, def_3par = 0, def_orb =  0, def_ftr =  1, def_tov =  1),
  "Inside, no-gamble defense" = c(tempo = 0, off_3par = -1, off_orb =  1, off_ftr =  0, off_tov =  0, def_3par = 0, def_orb = -1, def_ftr = -1, def_tov = -1))
arch_levels <- rownames(templates)
name_clusters <- function(centers) {   # cluster number -> archetype name
  if (nrow(centers) != 4) { warning("k is not 4: archetype names are generic"); return(setNames(paste("Archetype", seq_len(nrow(centers))), seq_len(nrow(centers)))) }
  perms <- as.matrix(expand.grid(rep(list(1:4), 4)))
  perms <- perms[apply(perms, 1, function(r) length(unique(r)) == 4), ]
  score <- apply(perms, 1, function(p) sum(centers[p, style] * templates[, style]))
  setNames(arch_levels, perms[which.max(score), ])
}
if (k_star != 4) arch_levels <- paste("Archetype", seq_len(k_star))
cl_name <- name_clusters(fit_k$centers)
ts$archetype <- factor(cl_name[as.character(fit_k$cluster)], arch_levels)
cent <- as_tibble(fit_k$centers, rownames = "cl") %>% mutate(archetype = factor(cl_name[cl], arch_levels)) %>% select(-cl)

# Robustness: raw (not quality-adjusted) z-scores, and pooled-across-seasons z-scores (the era problem).
fit_raw <- km(as.matrix(Z_raw[, style]), k_star, 100)
ari_raw <- ari(fit_k$cluster, fit_raw$cluster)
ts$archetype_raw <- factor(name_clusters(fit_raw$centers)[as.character(fit_raw$cluster)], arch_levels)
agree_raw <- mean(ts$archetype == ts$archetype_raw)
fit_pool <- km(as.matrix(Z_pool[, style]), k_star, 100)
era_f <- cut(ts$season, c(2007, 2012, 2021, 2026), labels = c("2007-08 to 2011-12", "2012-13 to 2020-21", "2021-22 to 2025-26"))
pool_three <- which.max(fit_pool$centers[, "off_3par"])
era_check <- tibble(era = levels(era_f),
  pooled_three_heavy_share = as.numeric(tapply(fit_pool$cluster == pool_three, era_f, mean)),
  within_season_pace_space_share = as.numeric(tapply(ts$archetype == "Pace and space", era_f, mean)),
  within_season_slow_perimeter_share = as.numeric(tapply(ts$archetype == "Slow and perimeter", era_f, mean)))
write_res(era_check, "era_check.csv")
r2_res <- summary(lm(rating ~ archetype, ts))$r.squared
r2_raw <- summary(lm(rating ~ factor(fit_raw$cluster), ts))$r.squared
cat(sprintf("ARI primary vs raw = %.2f (same name for %.0f%% of team-seasons); R2 of rating on archetype: adjusted %.3f, raw %.3f\n",
            ari_raw, 100 * agree_raw, r2_res, r2_raw))
write_res(tibble(check = c("ARI, quality-adjusted vs raw-feature archetypes", "Share of team-seasons with the same archetype name",
                           "R2 of rating on archetype (quality-adjusted)", "R2 of rating on archetype (raw features)"),
                 value = c(ari_raw, agree_raw, r2_res, r2_raw)), "clustering_checks.csv")

# Profiles: centroid z-scores plus the raw averages behind them, and quality by archetype.
raw_means <- ts %>% group_by(archetype) %>% summarise(across(all_of(style), mean)) %>%
  pivot_longer(-archetype, names_to = "feature", values_to = "raw_mean")
prof <- cent %>% pivot_longer(-archetype, names_to = "feature", values_to = "centroid_z") %>%
  left_join(raw_means, by = c("archetype", "feature")) %>%
  mutate(feature_label = style_lab[feature], side = ifelse(grepl("^def_", feature), "Defense (what opponents do)",
                                                            ifelse(feature == "tempo", "Pace", "Offense")))
write_res(prof, "archetype_profiles.csv")
p3 <- ggplot(prof %>% mutate(feature_label = factor(feature_label, style_lab),
                             side = factor(side, c("Pace", "Offense", "Defense (what opponents do)")),
                             archetype = factor(archetype, rev(arch_levels))),
             aes(feature_label, archetype, fill = pmax(pmin(centroid_z, 1), -1))) +
  geom_tile(colour = cs_ink[["surface"]], linewidth = 1) +
  geom_text(aes(label = sprintf("%+.1f", centroid_z)), size = 3.6, colour = cs_ink[["primary"]]) +
  facet_grid(. ~ side, scales = "free_x", space = "free_x") +
  scale_fill_gradient2(low = cs_div[["low"]], mid = cs_div[["mid"]], high = cs_div[["high"]], limits = c(-1, 1),
                       breaks = c(-1, 0, 1), labels = c("-1 SD", "0", "+1 SD"), name = "Center vs. similar teams") +
  guides(fill = guide_colourbar(barwidth = unit(14, "lines"), barheight = unit(0.6, "lines"), title.vjust = 0.9)) +
  scale_x_discrete(labels = function(x) gsub(" ", "\n", sub("Opp\\. ", "Opp. ", x))) +
  labs(title = "Four styles: fast shooters, slow shooters, pressure teams and inside teams",
       subtitle = "Archetype centers, in SDs from teams of similar rating in the same season (red = more, blue = less)",
       x = NULL, y = NULL,
       caption = sprintf("k-means, k = %d, on %s D1 team-seasons 2007-08 to 2025-26. Opp. turnover %% = turnovers forced. Source: ESPN via hoopR.",
                         k_star, format(nrow(ts), big.mark = ","))) +
  theme_cs() + theme(panel.grid.major = element_blank(), axis.line.x = element_blank(), legend.position = "bottom",
                     legend.title = element_text(colour = cs_ink[["secondary"]], size = 9),
                     axis.text.x = element_text(size = 8.5), axis.text.y = element_text(colour = cs_ink[["primary"]]))
save_fig(p3, fig("03_archetype_profiles.png"), width = 10, height = 4.6)

# ---- 5. Style map (PCA) -------------------------------------------------------------------------------------------
pca <- prcomp(X)
ve <- summary(pca)$importance[2, 1:2]
ts$pc1 <- pca$x[, 1]; ts$pc2 <- pca$x[, 2]
# Orient PC1 so that "more threes" points right and PC2 so that "faster" points up.
if (pca$rotation["off_3par", 1] < 0) { ts$pc1 <- -ts$pc1; pca$rotation[, 1] <- -pca$rotation[, 1] }
if (pca$rotation["tempo", 2] < 0)    { ts$pc2 <- -ts$pc2; pca$rotation[, 2] <- -pca$rotation[, 2] }
rot <- pca$rotation
stopifnot(rot["off_orb", 1] < 0, rot["off_ftr", 1] < 0, rot["off_tov", 1] < 0, rot["def_ftr", 1] < 0, rot["def_tov", 1] < 0,
          rot["def_orb", 2] > 0, rot["def_tov", 2] > 0)
pc_txt <- c(sprintf("PC1 (%.0f%% of variance): right = more threes; fewer offensive boards, free throws and turnovers at both ends", 100 * ve[1]),
            sprintf("PC2 (%.0f%%): up = faster, forces more turnovers, allows more offensive boards", 100 * ve[2]))
famous <- tribble(~season, ~team_id, ~label, ~hj, ~vj,
  2021L, "2250", "Gonzaga 2021",       1.1, 0.5,     2018L, "222", "Villanova 2018", -0.1, 0.5,
  2019L, "258",  "Virginia 2019",      1.1, 0.5,     2016L, "222", "Villanova 2016", 1.1, 0.5,
  2017L, "277",  "West Virginia 2017", -0.1, 0.5,    2015L, "96",  "Kentucky 2015",  -0.1, 1.6,
  2024L, "41",   "UConn 2024",         -0.1, 0.0,    2023L, "2509", "Purdue 2023",   -0.1, 0.5)
lab <- famous %>% inner_join(ts %>% select(season, team_id, pc1, pc2, archetype), by = c("season", "team_id"))
stopifnot(nrow(lab) == nrow(famous))
write_res(ts %>% transmute(season, team_id, team, archetype, archetype_raw_features = archetype_raw, rating = round(rating, 2),
                           across(all_of(style), ~ round(.x, 4)), pc1 = round(pc1, 3), pc2 = round(pc2, 3),
                           labeled = paste(season, team_id) %in% paste(famous$season, famous$team_id)),
          "team_season_archetypes.csv")
write_res(bind_rows(as_tibble(pca$rotation[, 1:2], rownames = "feature"),
                    tibble(feature = "variance_explained", PC1 = ve[1], PC2 = ve[2])), "style_map_loadings.csv")
p4 <- ggplot(ts, aes(pc1, pc2)) +
  geom_point(data = ts %>% select(-archetype), colour = cs_ink[["grid"]], size = 2, alpha = 0.5, stroke = 0) +
  geom_point(colour = cs_pal[["blue"]], size = 2, alpha = 0.18, stroke = 0) +
  geom_point(data = lab, colour = cs_ink[["primary"]], size = 2.6) +
  geom_text(data = lab, aes(label = label, hjust = hj, vjust = vj), size = 3.3, colour = cs_ink[["primary"]], fontface = "bold") +
  facet_wrap(~archetype, nrow = 2) +
  labs(title = "The archetypes are regions of one continuous cloud, not separate islands",
       subtitle = "Each team-season on the first two principal components of quality-adjusted style; gray = all teams",
       x = pc_txt[1], y = pc_txt[2],
       caption = sprintf("n = %s D1 team-seasons, 2007-08 to 2025-26. Labeled teams chosen in advance as well-known examples. Source: ESPN via hoopR.",
                         format(nrow(ts), big.mark = ","))) +
  theme_cs() + theme(axis.title = element_text(size = 9))
save_fig(p4, fig("04_style_map.png"), width = 9, height = 7.2)

# ---- 6. Archetype share over time -------------------------------------------------------------------------------
wilson <- function(x, n, z = 1.96) { p <- x / n; c0 <- p + z^2 / (2 * n); h <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2))
  cbind((c0 - h) / (1 + z^2 / n), (c0 + h) / (1 + z^2 / n)) }
share <- ts %>% count(season, archetype, .drop = FALSE) %>% group_by(season) %>% mutate(n_season = sum(n)) %>% ungroup() %>%
  mutate(share = n / n_season, lo = wilson(n, n_season)[, 1], hi = wilson(n, n_season)[, 2])
# Change in share, first five vs. last five seasons, with a bootstrap over team-seasons within season.
early <- 2008:2012; late <- 2022:2026
share_diff <- function(d) sapply(arch_levels, function(a) mean(d$archetype[d$season %in% late] == a) - mean(d$archetype[d$season %in% early] == a))
boot_sd <- replicate(2000, share_diff(ts %>% group_by(season) %>% slice_sample(prop = 1, replace = TRUE) %>% ungroup()))
share_change <- tibble(archetype = arch_levels, early_share = sapply(arch_levels, function(a) mean(ts$archetype[ts$season %in% early] == a)),
                       late_share = sapply(arch_levels, function(a) mean(ts$archetype[ts$season %in% late] == a)),
                       change = share_diff(ts), lo = apply(boot_sd, 1, quantile, 0.025), hi = apply(boot_sd, 1, quantile, 0.975))
write_res(share, "archetype_share.csv"); write_res(share_change, "archetype_share_change.csv")
print(share_change, width = 200)
sc_lab <- share_change %>% mutate(archetype = factor(archetype, arch_levels),
                                  txt = sprintf("%+.0f pts (95%% CI %+.0f to %+.0f)", 100 * change, 100 * lo, 100 * hi))
p5 <- ggplot(share %>% mutate(archetype = factor(archetype, arch_levels)), aes(season, share)) +
  geom_ribbon(aes(ymin = lo, ymax = hi), fill = cs_pal[["blue"]], alpha = 0.15) +
  geom_line(colour = cs_pal[["blue"]], linewidth = 0.9) + geom_point(colour = cs_pal[["blue"]], size = 2) +
  geom_hline(yintercept = 1 / k_star, colour = cs_ink[["baseline"]], linetype = "dashed") +
  geom_text(data = sc_lab, aes(x = 2008, y = 0.395, label = paste("Last 5 vs first 5 seasons:", txt)), hjust = 0, size = 3,
            colour = cs_ink[["secondary"]]) +
  facet_wrap(~archetype, nrow = 2) +
  scale_y_continuous(labels = scales::percent, limits = c(0.12, 0.40)) +
  scale_x_continuous(breaks = c(2010, 2016, 2022), labels = function(x) sprintf("%d-%02d", x - 1, x %% 100)) +
  labs(title = "Relative to each season's norms, styles shifted only a little in 19 years",
       subtitle = "Share of D1 team-seasons in each archetype; band = 95% Wilson interval; dashed line = equal shares",
       x = NULL, y = NULL,
       caption = "Change in percentage points, 2021-22 to 2025-26 vs. 2007-08 to 2011-12; 95% bootstrap CI over team-seasons. Source: ESPN via hoopR.") +
  theme_cs()
save_fig(p5, fig("05_archetype_share.png"), width = 9, height = 6)

# ---- 7. March: wins above expectation by archetype ----------------------------------------------------------------
tg <- ncaa %>% filter(season >= 2010) %>% group_by(season) %>% add_count(date, name = "games_that_day") %>%
  mutate(first_round = min(date[games_that_day >= 8]), first_four = date < first_round) %>% ungroup()
tg$pred <- mapply(function(s, h, a, n) predict_margin(fits[[as.character(s)]], h, a, n), tg$season, tg$home_id, tg$away_id, tg$neutral)
tg$sigma <- sapply(as.character(tg$season), function(s) fits[[s]]$sigma)
stopifnot(!anyNA(tg$pred))
tg <- tg %>% mutate(p_home = pnorm(pred / sigma), home_win = as.integer(margin > 0))
# Leave-one-tournament-out recalibration: scale c in pnorm(c * pred / sigma), fit by probit on the other tournaments.
tg$p_home_loto <- NA_real_
for (s in unique(tg$season)) {
  m <- glm(home_win ~ 0 + I(pred / sigma), family = binomial(link = "probit"), data = tg %>% filter(season != s))
  i <- tg$season == s
  tg$p_home_loto[i] <- pnorm(coef(m)[1] * tg$pred[i] / tg$sigma[i])
}
calib <- glm(home_win ~ I(pred / sigma), family = binomial(link = "probit"), data = tg)
cal_tab <- tibble(n_games = nrow(tg), brier = mean((tg$p_home - tg$home_win)^2),
                  brier_loto = mean((tg$p_home_loto - tg$home_win)^2),
                  probit_slope = coef(calib)[2], slope_se = sqrt(vcov(calib)[2, 2]),
                  mean_sigma = mean(tg$sigma))
write_res(cal_tab, "march_calibration.csv"); print(cal_tab)

side <- function(d, who) {
  if (who == "home") d %>% transmute(season, game_id, first_four, team_id = home_id, win = home_win, p = p_home, p_loto = p_home_loto)
  else d %>% transmute(season, game_id, first_four, team_id = away_id, win = 1L - home_win, p = 1 - p_home, p_loto = 1 - p_home_loto)
}
tgl <- bind_rows(side(tg, "home"), side(tg, "away"))
arch_tab <- ts %>% select(season, team_id, archetype, archetype_raw, rating)
wae_of <- function(d) d %>% group_by(season, team_id) %>%
  summarise(games = n(), wins = sum(win), expected = sum(p), wae = sum(win - p), wae_loto = sum(win - p_loto), .groups = "drop") %>%
  inner_join(arch_tab, by = c("season", "team_id"))
tw <- wae_of(tgl)
tw_noff <- wae_of(tgl %>% filter(!first_four))
n_unmatched <- n_distinct(paste(tgl$season, tgl$team_id)) - nrow(tw)
tw$wae_qadj <- residuals(lm(wae ~ rating, tw))

between_ss <- function(y, a) { m <- tapply(y, a, mean); n <- tapply(y, a, length); sum(n * (m - mean(y))^2, na.rm = TRUE) }
perm_test <- function(d, y, a, B = 10000) {
  obs <- between_ss(d[[y]], d[[a]])
  idx <- split(seq_len(nrow(d)), d$season)
  lab <- d[[a]]
  null <- replicate(B, { l <- lab; for (i in idx) l[i] <- l[i][sample.int(length(i))]; between_ss(d[[y]], l) })
  (1 + sum(null >= obs)) / (1 + B)
}
boot_means <- function(d, y, a, B = 4000) {
  ss <- unique(d$season); by_s <- split(d, d$season)
  t(replicate(B, { db <- bind_rows(by_s[as.character(sample(ss, replace = TRUE))]); tapply(db[[y]], db[[a]], mean) }))
}
summarise_variant <- function(d, y, a, variant) {
  bm <- boot_means(d, y, a)
  tibble(variant = variant, archetype = levels(d[[a]]),
         teams = as.integer(table(d[[a]])), games = as.numeric(tapply(d$games, d[[a]], sum)),
         wins = as.numeric(tapply(d$wins, d[[a]], sum)), expected_wins = as.numeric(tapply(d$expected, d[[a]], sum)),
         mean_wae = as.numeric(tapply(d[[y]], d[[a]], mean)),
         lo = apply(bm, 2, quantile, 0.025, na.rm = TRUE), hi = apply(bm, 2, quantile, 0.975, na.rm = TRUE),
         boot_se = apply(bm, 2, sd, na.rm = TRUE), perm_p_global = perm_test(d, y, a))
}
march <- summarise_variant(tw, "wae", "archetype", "Primary: quality-adjusted archetypes, fitted sigma") %>%
  mutate(mde_80 = 2.8 * boot_se)   # smallest true difference from the field this sample would detect 80% of the time
robust <- bind_rows(
  march %>% select(-mde_80),
  summarise_variant(tw, "wae", "archetype_raw", "Raw-feature archetypes"),
  summarise_variant(tw, "wae_loto", "archetype", "Sigma recalibrated leave-one-tournament-out"),
  summarise_variant(tw_noff, "wae", "archetype", "First Four games excluded"),
  summarise_variant(tw, "wae_qadj", "archetype", "WAE residualized on pre-tournament rating"))
write_res(march, "march_wae.csv"); write_res(robust, "march_robustness.csv")
print(as.data.frame(robust), digits = 3)

# Descriptive: who reached the last weekend (no test; small counts).
champ <- tg %>% filter(date == max(date), .by = season) %>% transmute(season, team_id = ifelse(home_win == 1, home_id, away_id))
ff <- tg %>% group_by(season) %>% filter(date >= sort(unique(date), decreasing = TRUE)[2]) %>% ungroup() %>%
  { bind_rows(transmute(., season, team_id = home_id), transmute(., season, team_id = away_id)) } %>% distinct()
deep <- tw %>% mutate(final_four = paste(season, team_id) %in% paste(ff$season, ff$team_id),
                      champion = paste(season, team_id) %in% paste(champ$season, champ$team_id)) %>%
  group_by(archetype) %>% summarise(tournament_teams = n(), mean_rating = mean(rating), final_four_teams = sum(final_four),
                                    champions = sum(champion), .groups = "drop") %>%
  left_join(ts %>% group_by(archetype) %>% summarise(team_seasons = n(), all_teams_mean_rating = mean(rating),
                                                     all_teams_mean_net_eff = mean(net_eff)), by = "archetype")
write_res(deep, "archetype_summary.csv"); print(deep)

p_glob <- march$perm_p_global[1]
p6d <- march %>% mutate(ylab = sprintf("%s\n%d teams: %.0f wins vs %.1f expected", archetype, teams, wins, expected_wins),
                         ylab = factor(ylab, rev(ylab[match(arch_levels, archetype)])))
p6 <- ggplot(p6d, aes(mean_wae, ylab)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]]) +
  geom_linerange(aes(xmin = lo, xmax = hi), colour = cs_pal[["blue"]], linewidth = 0.9) +
  geom_point(colour = cs_pal[["blue"]], size = 3) +
  geom_text(aes(label = sprintf("%+.2f", mean_wae)), vjust = -1.1, size = 3.3, colour = cs_ink[["secondary"]]) +
  labs(title = if (p_glob >= 0.05) "No style beat its ratings in March by more than chance" else
                 "Style is associated with March results beyond what ratings predict",
       subtitle = "Mean NCAA tournament wins above expectation per team, 2009-10 to 2025-26, with 95% CIs",
       x = "Wins above expectation per tournament team", y = NULL,
       caption = sprintf("Expectation: pre-tournament ridge ratings, pnorm(margin / sigma). CIs resample the 16 tournaments. Global permutation test p = %.2f.\n%d teams, %d games. Source: ESPN via hoopR.",
                         p_glob, nrow(tw), nrow(tg))) +
  theme_cs() + theme(axis.text.y = element_text(colour = cs_ink[["primary"]]))
save_fig(p6, fig("06_march_wae.png"), width = 9, height = 4.6)

cat(sprintf("unmatched tournament teams: %d; runtime %.1f min\n", n_unmatched, as.numeric(difftime(Sys.time(), t0, units = "mins"))))
