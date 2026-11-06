# Study 10: what monitoring would have caught.
# Replays 2025-26 week by week with the no-look-ahead backtest: v2.2 against KenPom FanMatch (rolling Brier),
# calibration drift by month, and four alert rules fixed before the replay. Each firing is checked against the
# following four weeks, and each rule's false-alarm rate is simulated under "nothing is wrong". Also draws the
# production pipeline's architecture.
#   Rscript studies/10-running-a-model-in-production/analysis.R   (needs private data; see ../02-judging-forecasts/forecast_tools.R)
source("R/data.R"); source("R/theme.R"); source("studies/02-judging-forecasts/forecast_tools.R")
suppressPackageStartupMessages({ library(tidyr); library(ggplot2) })

dir <- file.path(cs_root(), "studies", "10-running-a-model-in-production")
fig <- function(name) file.path(dir, "figures", name)
res <- function(df, name) write_csv(df, file.path(dir, "results", name))
src <- "\nSource: ESPN results via hoopR; KenPom ratings and FanMatch (private; aggregates only)."

f <- load_forecasts() %>% filter(!is.na(p_fanmatch), !is.na(p_v22))
start <- as.Date("2025-11-03")                      # Monday of opening week
f <- f %>% mutate(week = as.integer(game_date - start) %/% 7 + 1,
                  gap = brier_i(p_v22, home_win) - brier_i(p_fanmatch, home_win))
MIN_N <- 50                                         # weeks with fewer games (NCAA tournament) are not monitored
weeks <- f %>% count(week) %>% filter(n >= MIN_N) %>% pull(week)
fm <- f %>% filter(week %in% weeks)
cat(sprintf("%d games, %d monitored weeks (%d games)\n", nrow(f), length(weeks), nrow(fm)))

# ---- weekly statistics ----------------------------------------------------------------------------------
slope0 <- function(x, y) sum(x * y) / sum(x * x)
week_stats <- function(d) {
  d %>% group_by(week) %>%
    summarise(n = n(), week_start = start + 7 * (first(week) - 1),
              brier_v22 = mean(brier_i(p_v22, home_win)), brier_fanmatch = mean(brier_i(p_fanmatch, home_win)),
              gap_se = sd(gap) / sqrt(n()), gap = mean(gap),           # se first: it needs the per-game gaps
              citl = mean(p_v22) - mean(home_win), citl_se = sqrt(sum(p_v22 * (1 - p_v22))) / n(),
              slope = slope0(margin_v22, margin),
              slope_se = sqrt(sum((margin - slope * margin_v22)^2) / (n() - 1) / sum(margin_v22^2)),
              .groups = "drop")
}
ws <- week_stats(fm)

# rolling 4-week paired gap (pooled over the games of the last four monitored weeks)
roll4 <- bind_rows(lapply(seq_along(weeks), function(i) {
  w <- weeks[max(1, i - 3):i]; x <- fm$gap[fm$week %in% w]
  tibble(week = weeks[i], roll_n = length(x), roll_gap = mean(x), roll_se = sd(x) / sqrt(length(x)), roll_weeks = length(w))
}))
ws <- ws %>% left_join(roll4, by = "week")

# ---- the four alert rules (fixed before the replay) -----------------------------------------------------
TH_GAP <- 0.005
fire <- function(ws) {
  two <- function(x) x & dplyr::lag(x, default = FALSE)          # condition held this week and last week
  ws %>% mutate(
    A1_gap_threshold = two(gap > TH_GAP),
    A2_gap_significant = roll_weeks == 4 & (roll_gap - 1.96 * roll_se) > 0,
    A3_calibration = two(abs(citl) > 1.96 * citl_se),
    A4_margin_scale = two(abs(slope - 1) > 1.96 * slope_se))
}
rules <- c(A1_gap_threshold = "A1  Weekly Brier gap to KenPom above 0.005, two weeks running",
           A2_gap_significant = "A2  Four-week Brier gap to KenPom above zero (95%)",
           A3_calibration = "A3  Forecast vs observed home wins off by 2+ SE, two weeks running",
           A4_margin_scale = "A4  Margin slope differs from 1 by 2+ SE, two weeks running")
ws <- fire(ws)

# was a firing real? Check the same condition on the next four monitored weeks, pooled (out of sample).
confirm <- function(rule, w, dd = fm, wsd = ws) {
  nxt <- weeks[weeks > w][1:4]; nxt <- nxt[!is.na(nxt)]
  if (length(nxt) < 2) return(NA)
  d <- dd %>% filter(week %in% nxt); cur <- wsd %>% filter(week == w)
  switch(rule,
         A1_gap_threshold = , A2_gap_significant = mean(d$gap) - 1.96 * sd(d$gap) / sqrt(nrow(d)) > 0,
         A3_calibration = { e <- mean(d$p_v22) - mean(d$home_win); se <- sqrt(sum(d$p_v22 * (1 - d$p_v22))) / nrow(d)
                            abs(e) > 1.96 * se && sign(e) == sign(cur$citl) },
         A4_margin_scale = { s <- slope0(d$margin_v22, d$margin)
                             se <- sqrt(sum((d$margin - s * d$margin_v22)^2) / (nrow(d) - 1) / sum(d$margin_v22^2))
                             abs(s - 1) > 1.96 * se && sign(s - 1) == sign(cur$slope - 1) })
}
alerts <- ws %>% select(week, week_start, n, all_of(names(rules))) %>%
  pivot_longer(all_of(names(rules)), names_to = "rule", values_to = "fired") %>%
  rowwise() %>% mutate(confirmed_next_4_weeks = if (fired) confirm(rule, week) else NA) %>% ungroup() %>%
  mutate(rule_label = unname(rules[rule]))
res(ws, "weekly_monitoring.csv"); res(alerts %>% select(-rule_label), "alert_replay.csv")
fired <- alerts %>% filter(fired)
print(fired %>% select(rule, week, week_start, confirmed_next_4_weeks), n = 50)

# ---- false-alarm rates when nothing is wrong (simulated seasons) ----------------------------------------
# A1/A2: equal skill (each game's v2.2-minus-KenPom gap gets a random sign). A3: outcomes drawn from v2.2's own
# probabilities (perfect calibration). A4: v2.2's margin residuals, centered and shuffled within each week (an
# unbiased margin with slope 1).
set.seed(10)
S <- 300
sim <- bind_rows(lapply(seq_len(S), function(s) {
  d <- fm
  d$gap <- d$gap * sample(c(-1, 1), nrow(d), replace = TRUE)
  d$home_win <- rbinom(nrow(d), 1, d$p_v22)
  d <- d %>% group_by(week) %>% mutate(r = margin - margin_v22, margin = margin_v22 + sample(r - mean(r))) %>% ungroup()
  w <- week_stats(d)
  r4 <- bind_rows(lapply(seq_along(weeks), function(i) {
    ww <- weeks[max(1, i - 3):i]; x <- d$gap[d$week %in% ww]
    tibble(week = weeks[i], roll_n = length(x), roll_gap = mean(x), roll_se = sd(x) / sqrt(length(x)), roll_weeks = length(ww))
  }))
  w <- fire(w %>% left_join(r4, by = "week"))
  tibble(sim = s, rule = names(rules), firings = vapply(names(rules), function(r) sum(w[[r]]), numeric(1)))
}))
null_rates <- sim %>% group_by(rule) %>%
  summarise(seasons = n(), share_of_seasons_with_a_false_alarm = mean(firings > 0), false_alarms_per_season = mean(firings),
            .groups = "drop") %>%
  left_join(alerts %>% group_by(rule) %>% summarise(firings_2025_26 = sum(fired),
                                                    confirmed = sum(confirmed_next_4_weeks, na.rm = TRUE), .groups = "drop"),
            by = "rule") %>%
  mutate(rule_label = unname(rules[rule]), monitored_weeks = length(weeks))
res(null_rates, "alert_false_alarm_rates.csv"); print(null_rates, width = 200)

# robustness for A4: the slope with an intercept, so a home-court (level) error cannot pose as a scale error
a4b <- fm %>% group_by(week) %>%
  group_modify(function(d, k) { b <- coef(summary(lm(margin ~ margin_v22, data = d)))[2, ]
                                tibble(slope_with_intercept = b[["Estimate"]], se = b[["Std. Error"]]) }) %>% ungroup() %>%
  mutate(off = abs(slope_with_intercept - 1) > 1.96 * se, fired = off & dplyr::lag(off, default = FALSE)) %>%
  left_join(ws %>% select(week, week_start, slope_through_origin = slope, A4_margin_scale), by = "week")
res(a4b, "alert_A4_with_intercept.csv")
cat("A4 with intercept fired in weeks:", a4b$week[a4b$fired], "\n")

# positive control: would rules A1-A3 have caught last season's model (v2.1, with its known calibration defect)?
# Same replay with v2.1's probabilities in place of v2.2's. A4 needs a margin, which this backtest has only for v2.2.
f21 <- fm %>% mutate(p_v22 = p_v21, gap = brier_i(p_v21, home_win) - brier_i(p_fanmatch, home_win))
ws21 <- week_stats(f21) %>%
  left_join(bind_rows(lapply(seq_along(weeks), function(i) {
    w <- weeks[max(1, i - 3):i]; x <- f21$gap[f21$week %in% w]
    tibble(week = weeks[i], roll_n = length(x), roll_gap = mean(x), roll_se = sd(x) / sqrt(length(x)), roll_weeks = length(w))
  })), by = "week") %>% fire()
control <- ws21 %>% select(week, week_start, n, brier_v21 = brier_v22, brier_fanmatch, gap, citl,
                           A1_gap_threshold, A2_gap_significant, A3_calibration)
res(control, "alert_positive_control_v21.csv")
control_summary <- tibble(rule = c("A1_gap_threshold", "A2_gap_significant", "A3_calibration"),
                          weeks_fired = c(sum(control$A1_gap_threshold), sum(control$A2_gap_significant), sum(control$A3_calibration)),
                          first_week_start = as.Date(c(control$week_start[which(control$A1_gap_threshold)[1]],
                                                       control$week_start[which(control$A2_gap_significant)[1]],
                                                       control$week_start[which(control$A3_calibration)[1]])),
                          monitored_weeks = length(weeks))
res(control_summary, "alert_positive_control_summary.csv"); print(control_summary)
alerts21 <- ws21 %>% select(week, week_start, n, A1_gap_threshold, A2_gap_significant, A3_calibration) %>%
  mutate(A4_margin_scale = NA) %>%
  pivot_longer(all_of(names(rules)), names_to = "rule", values_to = "fired") %>%
  rowwise() %>% mutate(confirmed_next_4_weeks = if (isTRUE(fired)) confirm(rule, week, f21, ws21) else NA) %>% ungroup() %>%
  mutate(rule_label = unname(rules[rule]))
res(alerts21 %>% select(-rule_label), "alert_positive_control_v21_replay.csv")

# ---- figure 1: rolling Brier, v2.2 vs FanMatch ----------------------------------------------------------
top <- ws %>% select(week_start, `v2.2` = brier_v22, `KenPom FanMatch` = brier_fanmatch) %>%
  pivot_longer(-week_start, names_to = "series", values_to = "value") %>%
  mutate(panel = factor("Weekly Brier score", levels = c("Weekly Brier score", "v2.2 minus KenPom, same games (95% CI)")),
         lo = NA_real_, hi = NA_real_)
bot <- ws %>% transmute(week_start, series = "v2.2 minus KenPom", value = gap, lo = gap - 1.96 * gap_se,
                        hi = gap + 1.96 * gap_se,
                        panel = factor("v2.2 minus KenPom, same games (95% CI)", levels = levels(top$panel)))
p1d <- bind_rows(top, bot) %>%
  mutate(series = factor(series, levels = c("v2.2", "KenPom FanMatch", "v2.2 minus KenPom")))
thr <- tibble(panel = factor("v2.2 minus KenPom, same games (95% CI)", levels = levels(p1d$panel)), y = c(0, TH_GAP),
              what = c("zero", "A1 threshold (0.005)"))
lab1 <- top %>% filter(week_start == max(week_start)) %>% mutate(label_y = spread_labels(value, 0.012))
p1 <- ggplot(p1d, aes(week_start, value, colour = series)) +
  geom_hline(data = thr, aes(yintercept = y), colour = cs_ink[["baseline"]], linewidth = 0.8,
             linetype = c("solid", "dashed")) +
  geom_text(data = thr %>% filter(y > 0), aes(x = start, y = y, label = what), inherit.aes = FALSE, hjust = 0,
            vjust = 1.6, size = 3.1, colour = cs_ink[["secondary"]]) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, linewidth = 0.8, na.rm = TRUE) +
  geom_line(data = top, linewidth = 0.9) + geom_point(size = 2) +
  geom_text(data = lab1, aes(y = label_y, label = series), hjust = 0, nudge_x = 3, size = 3.2, show.legend = FALSE) +
  facet_wrap(~panel, ncol = 1, scales = "free_y") +
  scale_colour_manual(values = c(`v2.2` = cs_pal[["blue"]], `KenPom FanMatch` = cs_pal[["orange"]],
                                 `v2.2 minus KenPom` = cs_pal[["blue"]])) +
  scale_x_date(date_labels = "%b %d", date_breaks = "3 weeks", expand = expansion(mult = c(0.02, 0.2))) +
  labs(title = "Week to week, v2.2 never fell measurably behind KenPom's forecasts",
       subtitle = "Weekly Brier score of each forecaster (top) and the paired gap on the same games (bottom)",
       x = "Week starting", y = NULL,
       caption = paste0("2025-26 replay: ", format(nrow(fm), big.mark = ","), " games in ", length(weeks),
                        " weeks with 50+ games; v2.2 fit out of fold, KenPom snapshot as of each game day.", src)) +
  theme_cs() + theme(legend.position = "none")
save_fig(p1, fig("01_weekly_brier.png"), width = 9, height = 6.2)

# ---- figure 2: calibration drift by month ---------------------------------------------------------------
month_of <- function(d) factor(ifelse(format(d, "%m") %in% c("03", "04"), "Mar-Apr", format(d, "%b")),
                               levels = c("Nov", "Dec", "Jan", "Feb", "Mar-Apr"))
cal_month <- f %>% mutate(month = month_of(game_date)) %>% group_by(month) %>%
  group_modify(function(d, k) {
    fit <- glm(home_win ~ qlogis(clip(p_v22)), family = binomial, data = d)
    b <- coef(summary(fit))[2, ]
    e <- mean(d$p_v22) - mean(d$home_win); se <- sqrt(sum(d$p_v22 * (1 - d$p_v22))) / nrow(d)
    tibble(n = nrow(d), metric = factor(c("Forecast minus observed home-win rate (points)", "Calibration slope (1 = right)"),
                                        levels = c("Forecast minus observed home-win rate (points)", "Calibration slope (1 = right)")),
           est = c(100 * e, b[["Estimate"]]), lo = c(100 * (e - 1.96 * se), b[["Estimate"]] - 1.96 * b[["Std. Error"]]),
           hi = c(100 * (e + 1.96 * se), b[["Estimate"]] + 1.96 * b[["Std. Error"]]))
  }) %>% ungroup()
res(cal_month, "calibration_by_month.csv"); print(cal_month)

# is the early-season slope v2.2's alone? KenPom FanMatch's recalibration slope by month, for comparison
slope_fm <- f %>% mutate(month = month_of(game_date)) %>% group_by(month) %>%
  group_modify(function(d, k) {
    b <- coef(summary(glm(home_win ~ qlogis(clip(p_fanmatch)), family = binomial, data = d)))[2, ]
    tibble(n = nrow(d), slope = b[["Estimate"]], lo = b[["Estimate"]] - 1.96 * b[["Std. Error"]],
           hi = b[["Estimate"]] + 1.96 * b[["Std. Error"]])
  }) %>% ungroup()
res(slope_fm, "calibration_slope_fanmatch_by_month.csv")
# would recalibrating help out of sample? Fit the logistic recalibration on November, score December, and the reverse
recal <- bind_rows(lapply(list(c("11", "12"), c("12", "11")), function(z) {
  tr <- f %>% filter(format(game_date, "%m") == z[1]); te <- f %>% filter(format(game_date, "%m") == z[2])
  b <- coef(glm(home_win ~ qlogis(clip(p_v22)), family = binomial, data = tr))
  x <- brier_i(plogis(b[[1]] + b[[2]] * qlogis(clip(te$p_v22))), te$home_win) - brier_i(te$p_v22, te$home_win)
  bm <- boot_mean(x, 2000)
  tibble(fit_on = month.name[as.integer(z[1])], scored_on = month.name[as.integer(z[2])], n_scored = nrow(te),
         fitted_slope = b[[2]], brier_change = bm[["est"]], lo = bm[["lo"]], hi = bm[["hi"]])
}))
res(recal, "recalibration_out_of_sample.csv"); print(slope_fm); print(recal)
ref <- tibble(metric = c("Forecast minus observed home-win rate (points)", "Calibration slope (1 = right)"), y = c(0, 1))
p2 <- ggplot(cal_month, aes(month, est)) +
  geom_hline(data = ref, aes(yintercept = y), colour = cs_ink[["baseline"]], linewidth = 0.8) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, colour = cs_pal[["blue"]], linewidth = 0.8) +
  geom_point(size = 2.6, colour = cs_pal[["blue"]]) +
  facet_wrap(~metric, scales = "free_y") +
  labs(title = "Early-season forecasts were too timid; by January the slope was back near 1",
       subtitle = "By month: mean forecast minus observed home-win rate, and the slope of a logistic recalibration.\n95% intervals; zero and one mean no drift.",
       x = NULL, y = NULL,
       caption = paste0("2025-26: ", format(nrow(f), big.mark = ","), " games, v2.2 fit out of fold.", src)) +
  theme_cs() + theme(panel.spacing.x = unit(1.5, "lines"))
save_fig(p2, fig("02_calibration_by_month.png"), width = 9, height = 4.6)

# ---- figure 3: alert replay ------------------------------------------------------------------------------
lab_v22 <- "v2.2, the current model (replay)"; lab_v21 <- "v2.1, last season's model (known calibration defect)"
tiles <- bind_rows(alerts %>% mutate(model = lab_v22), alerts21 %>% mutate(model = lab_v21)) %>%
  mutate(model = factor(model, levels = c(lab_v22, lab_v21)),
         state = case_when(!fired ~ "Did not fire",
                                             is.na(confirmed_next_4_weeks) ~ "Fired, too late in the season to check",
                                             confirmed_next_4_weeks ~ "Fired, confirmed by the next 4 weeks",
                                             TRUE ~ "Fired, not confirmed"),
                           rule_label = factor(rule_label, levels = rev(unname(rules))))
tiles <- tiles %>% filter(!is.na(fired))
res(tiles %>% select(model, rule, week, week_start, state), "alert_timeline.csv")
p3 <- ggplot(tiles, aes(week_start, rule_label, fill = state)) +
  geom_tile(width = 6, height = 0.7, colour = cs_ink[["surface"]]) +
  scale_fill_manual(values = c("Did not fire" = cs_ink[["grid"]], "Fired, confirmed by the next 4 weeks" = cs_pal[["blue"]],
                               "Fired, not confirmed" = cs_pal[["orange"]], "Fired, too late in the season to check" = cs_ink[["muted"]]),
                    drop = FALSE) +
  scale_x_date(date_labels = "%b %d", date_breaks = "3 weeks") +
  scale_y_discrete(labels = function(x) gsub(", two weeks running| \\(95%\\)", "", substring(x, 5))) +
  facet_wrap(~model, ncol = 1, scales = "free_y") +
  labs(title = "The rules flagged v2.1's defect in week two and stayed quiet on v2.2, except for margin scale",
       subtitle = "Weeks in which each alert rule would have fired in a 2025-26 replay. Rules were fixed before the replay;\na firing is confirmed when the same condition holds on the next four weeks pooled. The backtest has no margin\nfor v2.1, so its margin rule is not shown.",
       x = "Week starting", y = NULL,
       caption = paste0("2025-26: ", length(weeks), " monitored weeks. False-alarm rates from ", S,
                        " simulated seasons are in results/alert_false_alarm_rates.csv.", src)) +
  guides(fill = guide_legend(nrow = 2)) +
  theme_cs() + theme(panel.grid.major.y = element_blank())
save_fig(p3, fig("03_alert_replay.png"), width = 10.5, height = 6.6)

# ---- figure 4: architecture -----------------------------------------------------------------------------
box <- tribble(
  ~id, ~x, ~y, ~w, ~h, ~group, ~label,
  "launchd", 1, 6.3, 1.9, 0.9, "Scheduling", "launchd (Mac)\n06:30 CT full run\n16:30 CT line refresh",
  "config", 1, 4.4, 1.9, 0.9, "Configuration", "config/season.yml\nseason, phases, dates\n(read by R, Python, shell)",
  "espn", 1, 2.9, 1.9, 0.55, "Sources", "ESPN via hoopR",
  "kenpom", 1, 2.15, 1.9, 0.55, "Sources", "KenPom API + FanMatch",
  "bart", 1, 1.4, 1.9, 0.55, "Sources", "Barttorvik (free)",
  "market", 1, 0.65, 1.9, 0.55, "Sources", "Market lines API (capped)",
  "runner", 4, 4.0, 2.3, 4.6, "Pipeline", paste(
    "daily_update.sh", "", "1 import (core)", "2 grade yesterday", "3 review", "4 KenPom (core)", "5 Barttorvik",
    "6 market lines", "7 predict v2.2 (core)", "8 record (core)", "9 accuracy", "10 slate (core)", "11 phase steps",
    "12 vault notes", "13 mappings, backup", sep = "\n"),
  "db", 7, 5.2, 2.0, 1.0, "Storage", "SQLite database\npredictions, grades,\nratings, lines",
  "backup", 7, 3.75, 2.0, 0.8, "Storage", "Local snapshots\n(14 kept; off-machine\ncopy still open)",
  "outputs", 7, 2.3, 2.0, 0.9, "Outputs", "Daily slate (markdown)\nCSVs, scoreboard\nObsidian note",
  "logs", 7, 0.95, 2.0, 0.8, "Health", "logs/<date>/<step>.log\nRESULT line, exit codes",
  "health", 10, 0.95, 2.3, 1.15, "Health", "Checks a person runs\nquick_lookup status: missed or\nfailed runs, ungraded games\nsmoke_test.sh (reads logs + DB)",
  "user", 10, 3.0, 2.3, 0.8, "Outputs", "cv reads the slate\n(no alerts are sent)")
edges <- tribble(
  ~from, ~to,
  "launchd", "runner", "config", "runner", "espn", "runner", "kenpom", "runner", "bart", "runner", "market", "runner",
  "runner", "db", "db", "backup", "runner", "outputs", "runner", "logs", "logs", "health",
  "outputs", "user", "health", "user")
anchor <- function(id, side) {
  b <- box[box$id == id, ]
  switch(side, right = c(b$x + b$w / 2, b$y), left = c(b$x - b$w / 2, b$y), top = c(b$x, b$y + b$h / 2), bottom = c(b$x, b$y - b$h / 2))
}
seg <- bind_rows(lapply(seq_len(nrow(edges)), function(i) {
  a <- box[box$id == edges$from[i], ]; b <- box[box$id == edges$to[i], ]
  if (abs(a$x - b$x) < 0.1) {                     # same column: vertical arrow
    s <- if (a$y > b$y) anchor(a$id, "bottom") else anchor(a$id, "top")
    e <- if (a$y > b$y) anchor(b$id, "top") else anchor(b$id, "bottom")
  } else {
    s <- anchor(a$id, "right"); e <- anchor(b$id, "left")
    if (b$id == "runner") e[2] <- min(max(a$y, b$y - b$h / 2 + 0.2), b$y + b$h / 2 - 0.2)
    if (a$id == "runner") s[2] <- min(max(b$y, a$y - a$h / 2 + 0.2), a$y + a$h / 2 - 0.2)
  }
  tibble(from = edges$from[i], to = edges$to[i], x = s[1], y = s[2], xend = e[1], yend = e[2])
}))
grp_col <- c(Scheduling = cs_pal[["blue"]], Configuration = cs_pal[["blue"]], Sources = cs_ink[["muted"]],
             Pipeline = cs_pal[["blue"]], Storage = cs_pal[["orange"]], Outputs = cs_pal[["green"]], Health = cs_pal[["orange"]])
p4 <- ggplot() +
  geom_segment(data = seg, aes(x = x, y = y, xend = xend, yend = yend), colour = cs_ink[["muted"]], linewidth = 0.6,
               arrow = arrow(length = unit(0.12, "inches"), type = "closed")) +
  geom_rect(data = box, aes(xmin = x - w / 2, xmax = x + w / 2, ymin = y - h / 2, ymax = y + h / 2, colour = group),
            fill = cs_ink[["surface"]], linewidth = 0.9) +
  geom_text(data = box, aes(x = x, y = y, label = label), size = 3.1, colour = cs_ink[["primary"]], lineheight = 0.95) +
  scale_colour_manual(values = grp_col, guide = "none") +
  coord_cartesian(xlim = c(-0.1, 11.2), ylim = c(0.2, 6.9), expand = FALSE) +
  labs(title = "One scheduled script, one database, and health checks a person runs",
       subtitle = "The 2026-27 pipeline. Core steps (import, KenPom, predict, record, slate) fail the run; the others are logged and skipped.",
       caption = "Designed 2026-11-05; the first scheduled run is 2026-11-06. Backups are local only, and nothing alerts on failure.") +
  theme_void(base_size = 12) +
  theme(plot.background = element_rect(fill = cs_ink[["surface"]], colour = NA),
        plot.title = element_text(colour = cs_ink[["primary"]], face = "bold", size = rel(1.15)),
        plot.subtitle = element_text(colour = cs_ink[["secondary"]], margin = margin(b = 8)),
        plot.caption = element_text(colour = cs_ink[["muted"]], hjust = 0, size = rel(0.8)),
        plot.title.position = "plot", plot.caption.position = "plot", plot.margin = margin(12, 16, 10, 12))
save_fig(p4, fig("04_architecture.png"), width = 11, height = 6.6)
res(box %>% select(id, group, label) %>% mutate(label = gsub("\n", " / ", label)), "architecture_components.csv")
res(edges, "architecture_edges.csv")
cat("done\n")
