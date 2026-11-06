# Study 02: how good is a simple ratings model, really?
# Scores four forecasters of the home team's win probability on 2025-26 (no look-ahead): v2.2 (the 3-parameter
# model), v2.1 (last season's model, as shipped), KenPom FanMatch, and the de-vigged betting market (from
# 2026-01-22). Brier, log loss, reliability, CORP decomposition, paired bootstrap CIs, Brier by month, and the
# early-season margin scale.
#   Rscript studies/02-judging-forecasts/analysis.R      (needs the private export; see forecast_tools.R)
source("R/data.R"); source("R/theme.R"); source("studies/02-judging-forecasts/forecast_tools.R")
suppressPackageStartupMessages({ library(tidyr); library(ggplot2) })

dir <- file.path(cs_root(), "studies", "02-judging-forecasts")
fig <- function(name) file.path(dir, "figures", name)
res <- function(df, name) write_csv(df, file.path(dir, "results", name))
B <- 2000

f <- load_forecasts()
common <- f %>% filter(!is.na(p_fanmatch), !is.na(p_v22))        # every model has a forecast
mkt <- common %>% filter(!is.na(p_market))                         # the market's subset (2026-01-22 on)
cat(sprintf("games %d; common %d; market subset %d (%s to %s)\n", nrow(f), nrow(common), nrow(mkt),
            min(mkt$game_date), max(mkt$game_date)))

models <- c(p_v22 = "v2.2", p_fanmatch = "KenPom FanMatch", p_v21 = "v2.1 (as shipped)", p_market = "Market")
src <- "\nSource: ESPN results via hoopR; KenPom ratings and FanMatch; consensus moneylines (private; aggregates only)."

# ---- 1. scores and paired differences --------------------------------------------------------------------
score_rows <- function(d, cols, subset) {
  bind_rows(lapply(cols, function(m) {
    b <- boot_mean(brier_i(d[[m]], d$home_win), B); l <- boot_mean(logloss_i(d[[m]], d$home_win), B)
    tibble(subset = subset, model = models[[m]], n = nrow(d),
           brier = b[["est"]], brier_lo = b[["lo"]], brier_hi = b[["hi"]],
           log_loss = l[["est"]], log_loss_lo = l[["lo"]], log_loss_hi = l[["hi"]],
           accuracy = mean((d[[m]] >= 0.5) == (d$home_win == 1)))
  }))
}
scores <- bind_rows(score_rows(common, c("p_v22", "p_fanmatch", "p_v21"), "All games"),
                    score_rows(mkt, c("p_v22", "p_fanmatch", "p_v21", "p_market"), "From 2026-01-22 (market subset)"))
res(scores, "scores.csv")

paired <- function(d, a, b, label) {
  bind_rows(
    tibble(metric = "Brier score", x = brier_i(d[[a]], d$home_win) - brier_i(d[[b]], d$home_win)),
    tibble(metric = "Log loss", x = logloss_i(d[[a]], d$home_win) - logloss_i(d[[b]], d$home_win))) %>%
    group_by(metric) %>%
    summarise(comparison = label, n = n(), est = mean(x),
              lo = boot_mean(x, B)[["lo"]], hi = boot_mean(x, B)[["hi"]], .groups = "drop")
}
diffs <- bind_rows(
  paired(common, "p_v22", "p_fanmatch", sprintf("v2.2 minus KenPom FanMatch\n(%s games)", format(nrow(common), big.mark = ","))),
  paired(common, "p_v22", "p_v21", sprintf("v2.2 minus v2.1 as shipped\n(%s games)", format(nrow(common), big.mark = ","))),
  paired(mkt, "p_v22", "p_market", sprintf("v2.2 minus the market\n(%s games from Jan 22)", format(nrow(mkt), big.mark = ","))))
res(diffs %>% mutate(comparison = gsub("\n", " ", comparison)), "score_differences.csv")
print(diffs)

diffs$comparison <- factor(diffs$comparison, levels = rev(unique(diffs$comparison)))
p1 <- ggplot(diffs, aes(est, comparison)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.8) +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0.15, orientation = "y", colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(size = 2.6, colour = cs_pal[["blue"]]) +
  geom_label(aes(label = sprintf("%+.4f", est)), vjust = -0.6, size = 3.3, colour = cs_ink[["secondary"]],
             fill = cs_ink[["surface"]], border.colour = NA, label.padding = unit(0.1, "lines")) +
  facet_wrap(~metric, scales = "free_x") +
  labs(title = "v2.2 is within a hair of KenPom, well ahead of v2.1, and behind the market",
       subtitle = "Paired difference in score on the same games, with 95% bootstrap intervals.\nRight of zero = v2.2 is worse; left of zero = v2.2 is better.",
       x = "v2.2's mean score minus the other forecaster's", y = NULL,
       caption = paste0("2025-26, D1 vs D1; KenPom snapshot as of each game day; v2.2 fit out of fold.", src)) +
  theme_cs() + theme(panel.spacing.x = unit(1.5, "lines"))
save_fig(p1, fig("01_score_differences.png"), width = 9, height = 4.6)

# ---- 2. reliability diagrams ----------------------------------------------------------------------------
rel_data <- function(d, m, label, nbin = 10) {
  d %>% mutate(p = .data[[m]], bin = pmin(floor(p * nbin), nbin - 1)) %>%
    group_by(bin) %>%
    summarise(n = n(), mean_forecast = mean(p), observed = mean(home_win), wins = sum(home_win), .groups = "drop") %>%
    mutate(model = label, lo = wilson(wins, n)[, "lo"], hi = wilson(wins, n)[, "hi"])
}
rel <- bind_rows(rel_data(common, "p_v21", "v2.1 (as shipped)"), rel_data(common, "p_v22", "v2.2"),
                 rel_data(common, "p_fanmatch", "KenPom FanMatch"), rel_data(mkt, "p_market", "Market (from Jan 22)"))
rel$model <- factor(rel$model, levels = c("v2.1 (as shipped)", "v2.2", "KenPom FanMatch", "Market (from Jan 22)"))
res(rel %>% select(model, bin, n, mean_forecast, observed, lo, hi), "reliability.csv")

p2 <- ggplot(rel, aes(mean_forecast, observed)) +
  geom_abline(slope = 1, intercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.8) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(size = 2.2, colour = cs_pal[["blue"]]) +
  facet_wrap(~model, nrow = 1) +
  scale_x_continuous(labels = scales::percent, breaks = c(0, .5, 1)) +
  scale_y_continuous(labels = scales::percent, breaks = seq(0, 1, .25)) +
  coord_equal(xlim = c(0, 1), ylim = c(0, 1)) +
  labs(title = "v2.1 underrated home teams across the board; the others sit on the diagonal",
       subtitle = "Home team's forecast win probability (10 bins) against how often it won, with 95% Wilson intervals",
       x = "Forecast home win probability", y = "Home team won",
       caption = paste0("2025-26: ", format(nrow(common), big.mark = ","), " games; ", format(nrow(mkt), big.mark = ","),
                       " for the market.", src)) +
  theme_cs() + theme(panel.spacing.x = unit(1.2, "lines"))
save_fig(p2, fig("02_reliability.png"), width = 10, height = 4.1)

# ---- 3. Murphy decomposition: reliability, resolution, uncertainty ---------------------------------------
# Binned (10 bins of width 0.1, as in the reliability diagram): Brier = REL - RES + UNC + remainder, where the
# remainder is the within-bin variation the bins average away. The bin-free CORP version (isotonic
# recalibration) is computed as a check; its bootstrap is biased upward for miscalibration, so only its point
# estimates are reported.
murphy <- function(p, y, nbin = 10) {
  bin <- factor(pmin(floor(p * nbin), nbin - 1), levels = 0:(nbin - 1)); N <- length(y); ob <- mean(y)
  nk <- as.numeric(table(bin)); fk <- tapply(p, bin, mean); ok <- tapply(y, bin, mean)
  keep <- nk > 0
  rel <- sum(nk[keep] * (fk[keep] - ok[keep])^2) / N; rs <- sum(nk[keep] * (ok[keep] - ob)^2) / N; unc <- ob * (1 - ob)
  bs <- mean((p - y)^2)
  c(brier = bs, rel = rel, res = rs, unc = unc, remainder = bs - (rel - rs + unc))
}
murphy_boot <- function(d, m, label, subset, B = 1000) {
  set.seed(2)
  pt <- murphy(d[[m]], d$home_win); cp <- corp(d[[m]], d$home_win)
  bs <- t(vapply(seq_len(B), function(i) { s <- sample.int(nrow(d), replace = TRUE); murphy(d[[m]][s], d$home_win[s]) },
                 numeric(5)))
  tibble(subset = subset, model = label, n = nrow(d),
         component = c("Reliability (lower is better)", "Resolution (higher is better)"),
         est = pt[c("rel", "res")], lo = apply(bs[, c("rel", "res")], 2, quantile, 0.025),
         hi = apply(bs[, c("rel", "res")], 2, quantile, 0.975), brier = pt[["brier"]], uncertainty = pt[["unc"]],
         remainder = pt[["remainder"]], corp_miscalibration = cp[["mcb"]], corp_discrimination = cp[["dsc"]])
}
dec <- bind_rows(
  murphy_boot(common, "p_v21", "v2.1 (as shipped)", "All games"),
  murphy_boot(common, "p_v22", "v2.2", "All games"),
  murphy_boot(common, "p_fanmatch", "KenPom FanMatch", "All games"),
  murphy_boot(mkt, "p_v22", "v2.2", "From Jan 22"),
  murphy_boot(mkt, "p_fanmatch", "KenPom FanMatch", "From Jan 22"),
  murphy_boot(mkt, "p_market", "Market", "From Jan 22"))
res(dec, "murphy_decomposition.csv")
print(dec %>% select(subset, model, component, est, lo, hi, remainder, corp_miscalibration, corp_discrimination), width = 200)

lab_all <- sprintf("All games (n = %s)", format(nrow(common), big.mark = ","))
lab_mkt <- sprintf("From Jan 22 (n = %s)", format(nrow(mkt), big.mark = ","))
dec <- dec %>% mutate(model = factor(model, levels = rev(c("v2.1 (as shipped)", "v2.2", "KenPom FanMatch", "Market"))),
                      subset = factor(ifelse(subset == "All games", lab_all, lab_mkt), levels = c(lab_all, lab_mkt)),
                      component = factor(component, levels = c("Reliability (lower is better)", "Resolution (higher is better)")))
p3 <- ggplot(dec, aes(est, model)) +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0.2, orientation = "y", colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(size = 2.6, colour = cs_pal[["blue"]]) +
  geom_text(aes(label = sprintf("%.4f", est)), vjust = -1, size = 3.1, colour = cs_ink[["secondary"]]) +
  facet_grid(subset ~ component, scales = "free", space = "free_y") +
  scale_x_continuous(expand = expansion(mult = c(0.08, 0.08))) +
  labs(title = "v2.1 lost on calibration; the market wins on resolution",
       subtitle = "Murphy decomposition: Brier = reliability - resolution + uncertainty (10 bins). Reliability measures\nmiscalibration; resolution, how well forecasts separate wins from losses. 95% bootstrap intervals.",
       x = NULL, y = NULL, caption = paste0("2025-26.", src)) +
  theme_cs() + theme(panel.spacing = unit(1.2, "lines"))
save_fig(p3, fig("03_murphy_decomposition.png"), width = 9, height = 5.2)

# ---- 4. Brier by month ----------------------------------------------------------------------------------
monthly <- common %>%
  mutate(month = factor(ifelse(format(game_date, "%m") %in% c("03", "04"), "Mar-Apr", format(game_date, "%b")),
                        levels = c("Nov", "Dec", "Jan", "Feb", "Mar-Apr"))) %>%
  pivot_longer(c(p_v22, p_fanmatch, p_v21, p_market), names_to = "m", values_to = "p") %>%
  filter(!is.na(p)) %>%
  group_by(month, m) %>%
  summarise(n = n(), brier = mean(brier_i(p, home_win)), lo = boot_mean(brier_i(p, home_win), 1000)[["lo"]],
            hi = boot_mean(brier_i(p, home_win), 1000)[["hi"]], sharpness = mean(abs(p - 0.5)), .groups = "drop") %>%
  mutate(model = factor(unname(models[m]), levels = unname(models)))
res(monthly %>% select(month, model, n, brier, lo, hi, sharpness), "brier_by_month.csv")
gap_month <- common %>%
  mutate(month = factor(ifelse(format(game_date, "%m") %in% c("03", "04"), "Mar-Apr", format(game_date, "%b")),
                        levels = c("Nov", "Dec", "Jan", "Feb", "Mar-Apr")),
         d = brier_i(p_v22, home_win) - brier_i(p_fanmatch, home_win)) %>%
  group_by(month) %>%
  summarise(n = n(), gap = mean(d), lo = boot_mean(d, 1000)[["lo"]], hi = boot_mean(d, 1000)[["hi"]], .groups = "drop")
res(gap_month, "brier_gap_v22_minus_fanmatch_by_month.csv")
print(gap_month)

ends <- monthly %>% group_by(model) %>% filter(as.integer(month) == max(as.integer(month))) %>% ungroup() %>%
  mutate(label_y = spread_labels(brier, 0.0042))
p4 <- ggplot(monthly, aes(month, brier, colour = model, group = model)) +
  geom_line(linewidth = 0.9) + geom_point(size = 2.2) +
  geom_text(data = ends, aes(y = label_y, label = model), hjust = 0, nudge_x = 0.12, size = 3.3, show.legend = FALSE) +
  scale_colour_manual(values = unname(cs_pal[c("blue", "orange", "aqua", "yellow")])) +
  scale_x_discrete(expand = expansion(add = c(0.3, 1.6))) +
  labs(title = "Month-to-month swings dwarf the gaps between forecasters",
       subtitle = "Mean Brier score by month (lower is better). November and December score best because\nnon-conference schedules are full of mismatches; the market has lines from Jan 22 only.",
       x = NULL, y = "Brier score", caption = paste0("2025-26: ", format(nrow(common), big.mark = ","), " games.", src)) +
  theme_cs() + theme(legend.position = "none")
save_fig(p4, fig("04_brier_by_month.png"), width = 8, height = 5)

# ---- 5. early-season margin scale -----------------------------------------------------------------------
slope0 <- function(x, y) sum(x * y) / sum(x * x)          # least squares through the origin
boot_slope <- function(x, y, B = 1000, seed = 3) {
  set.seed(seed); n <- length(x)
  s <- vapply(seq_len(B), function(i) { j <- sample.int(n, n, replace = TRUE); slope0(x[j], y[j]) }, numeric(1))
  c(est = slope0(x, y), lo = unname(quantile(s, .025)), hi = unname(quantile(s, .975)))
}
start <- as.Date("2025-11-03")
ms <- f %>% mutate(week = as.integer(game_date - start) %/% 7 + 1,
                   period = ifelse(game_date < as.Date("2026-01-01"), "Nov-Dec",
                                   ifelse(game_date < as.Date("2026-03-01"), "Jan-Feb", "Mar-Apr")))
weekly_slope <- ms %>% group_by(week) %>%
  summarise(week_start = min(game_date), n = n(), slope = slope0(margin_v22_full, margin),
            lo = boot_slope(margin_v22_full, margin)[["lo"]], hi = boot_slope(margin_v22_full, margin)[["hi"]],
            .groups = "drop")
period_slope <- ms %>% group_by(period) %>%
  summarise(n = n(), slope = slope0(margin_v22_full, margin), lo = boot_slope(margin_v22_full, margin)[["lo"]],
            hi = boot_slope(margin_v22_full, margin)[["hi"]],
            slope_out_of_fold = slope0(margin_v22, margin), .groups = "drop")
res(weekly_slope, "margin_slope_by_week.csv"); res(period_slope, "margin_slope_by_period.csv")
print(period_slope)

# out of sample: a scale fit on November, scored on December, and the reverse (mean absolute margin error)
nov <- ms %>% filter(format(game_date, "%m") == "11"); decm <- ms %>% filter(format(game_date, "%m") == "12")
oos <- bind_rows(lapply(list(list("November", "December", nov, decm), list("December", "November", decm, nov)), function(z) {
  k <- slope0(z[[3]]$margin_v22_full, z[[3]]$margin); te <- z[[4]]
  dx <- abs(k * te$margin_v22_full - te$margin) - abs(te$margin_v22_full - te$margin)
  b <- boot_mean(dx, B)
  tibble(fit_on = z[[1]], scored_on = z[[2]], n_scored = nrow(te), scale = k,
         mae_unscaled = mean(abs(te$margin_v22_full - te$margin)), mae_scaled = mean(abs(k * te$margin_v22_full - te$margin)),
         change = b[["est"]], change_lo = b[["lo"]], change_hi = b[["hi"]])
}))
# win probabilities barely move: scale the Nov-Dec margins by 1.13 and refit sigma by likelihood
nd <- ms %>% filter(period == "Nov-Dec")
fit_sigma <- function(m, y) optimize(function(s) mean(logloss_i(pnorm(m / s), y)), c(5, 20))$minimum
s1 <- fit_sigma(nd$margin_v22_full, nd$home_win); sk <- fit_sigma(1.13 * nd$margin_v22_full, nd$home_win)
oos$brier_change_nov_dec_if_scaled <- mean(brier_i(pnorm(1.13 * nd$margin_v22_full / sk), nd$home_win)) -
  mean(brier_i(pnorm(nd$margin_v22_full / s1), nd$home_win))
res(oos, "margin_scale_out_of_sample.csv")
print(oos)

p5 <- ggplot(weekly_slope %>% filter(n >= 50), aes(week_start, slope)) +
  annotate("rect", xmin = start - 3, xmax = as.Date("2026-01-01"), ymin = -Inf, ymax = Inf,
           fill = cs_ink[["grid"]], alpha = 0.45) +
  annotate("text", x = as.Date("2025-11-05"), y = 1.5, label = "Nov-Dec: 2026-27 margins are scaled x1.13",
           hjust = 0, size = 3.3, colour = cs_ink[["secondary"]]) +
  geom_hline(yintercept = 1, colour = cs_ink[["baseline"]], linewidth = 0.8) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(size = 2.4, colour = cs_pal[["blue"]]) +
  scale_x_date(date_labels = "%b %d", date_breaks = "3 weeks") +
  labs(title = "Early-season margins ran bigger than the ratings implied",
       subtitle = "Weekly slope of the actual home margin on v2.2's margin (through the origin), 95% bootstrap intervals.\nAbove 1 = real margins were larger than predicted.",
       x = "Week starting", y = "Slope",
       caption = paste0("2025-26: ", format(nrow(f), big.mark = ","), " games; weeks with fewer than 50 games (NCAA tournament) are in the CSV only.", src)) +
  theme_cs()
save_fig(p5, fig("05_margin_scale_by_week.png"), width = 8.5, height = 5)

# ---- 6. does the line move toward the model? (counts from the private research note) --------------------
lm_tab <- tibble(forecaster = c("v2.2", "KenPom FanMatch"), games = c(143, 192), moved_toward = c(77, 97)) %>%
  mutate(share = moved_toward / games, lo = wilson(moved_toward, games)[, "lo"], hi = wilson(moved_toward, games)[, "hi"])
res(lm_tab, "line_moves_toward_forecaster.csv")
print(lm_tab)

# ---- margin error (points) on the same games -----------------------------------------------------------
me <- bind_rows(
  f %>% filter(!is.na(margin_v22)) %>% summarise(source = "v2.2", n = n(), rmse = sqrt(mean((margin - margin_v22)^2)),
                                                 mean_error = mean(margin - margin_v22)),
  f %>% filter(!is.na(margin_fanmatch)) %>% summarise(source = "KenPom FanMatch", n = n(),
                                                      rmse = sqrt(mean((margin - margin_fanmatch)^2)), mean_error = mean(margin - margin_fanmatch)),
  f %>% filter(!is.na(margin_market)) %>% summarise(source = "Market", n = n(), rmse = sqrt(mean((margin - margin_market)^2)),
                                                    mean_error = mean(margin - margin_market)),
  f %>% filter(!is.na(margin_market)) %>% summarise(source = "v2.2 (market games)", n = n(),
                                                    rmse = sqrt(mean((margin - margin_v22)^2)), mean_error = mean(margin - margin_v22)))
res(me, "margin_error.csv")
print(me)
cat("done\n")
