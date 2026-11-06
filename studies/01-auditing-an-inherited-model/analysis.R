# Study 01: what I found when I audited last season's model.
# A model-risk review of the 2025-26 pipeline (model v2.1), done 2026-11-05. Measures the impact of each defect
# on 2025-26 data: the holdout backtest (no look-ahead), the season's live prediction and tracking records, and
# four seasons of conference-tournament games. Publishes aggregates only.
#   Rscript studies/01-auditing-an-inherited-model/analysis.R     (needs private data; see ../02-judging-forecasts/forecast_tools.R)
source("R/data.R"); source("R/theme.R"); source("studies/02-judging-forecasts/forecast_tools.R")
suppressPackageStartupMessages({ library(tidyr); library(ggplot2); library(DBI); library(RSQLite) })

dir <- file.path(cs_root(), "studies", "01-auditing-an-inherited-model")
fig <- function(name) file.path(dir, "figures", name)
res <- function(df, name) write_csv(df, file.path(dir, "results", name))
src <- "\nSource: ESPN results via hoopR; KenPom ratings; the pipeline's 2025-26 records (private; aggregates only)."
B <- 2000

# ---- inputs ---------------------------------------------------------------------------------------------
f <- load_forecasts() %>% filter(!is.na(p_fanmatch), !is.na(p_v22))
ct <- read_csv(private_export("conf_tournaments_2023_2026.csv", file.path(dir, "export_conf_tournaments.py")),
               show_col_types = FALSE, col_types = cols(game_id = "c", game_date = "D"))
arch <- dbConnect(SQLite(), file.path(private_repo(), "data", "archive", "ncaab_analytics_2026_final.db"),
                  flags = SQLITE_RO)
on.exit(dbDisconnect(arch), add = TRUE)

# ---- 1. calibration table applied only when the home team was favored ----------------------------------
side_tab <- function(d, m, label) {
  d %>% transmute(conf = pmax(.data[[m]], 1 - .data[[m]]), hit = ifelse(.data[[m]] >= 0.5, home_win, 1 - home_win),
                  side = ifelse(.data[[m]] >= 0.5, "Home team favored", "Away team favored"), model = label)
}
sides <- bind_rows(side_tab(f, "p_v21", "v2.1 as shipped"), side_tab(f, "p_v21_sym", "v2.1, table applied to both sides"),
                   side_tab(f, "p_v22", "v2.2 (replacement)"))
by_side <- sides %>% group_by(model, side) %>%
  summarise(n = n(), claimed = mean(conf), won = mean(hit), wins = sum(hit), .groups = "drop") %>%
  bind_rows(sides %>% group_by(model) %>% summarise(side = "All forecasts", n = n(), claimed = mean(conf), won = mean(hit),
                                                    wins = sum(hit), .groups = "drop")) %>%
  mutate(won_lo = wilson(wins, n)[, "lo"], won_hi = wilson(wins, n)[, "hi"], gap = won - claimed) %>%
  select(-wins) %>% arrange(model, side)
res(by_side, "calibration_by_side.csv")
print(by_side, width = 200)

cal_bins <- sides %>% filter(model != "v2.1, table applied to both sides") %>%
  mutate(bin = cut(conf, c(0.5, 0.6, 0.7, 0.8, 0.9, 1), include.lowest = TRUE)) %>%
  group_by(model, side, bin) %>%
  summarise(n = n(), claimed = mean(conf), won = mean(hit), wins = sum(hit), .groups = "drop") %>%
  mutate(lo = wilson(wins, n)[, "lo"], hi = wilson(wins, n)[, "hi"]) %>% select(-wins)
res(cal_bins, "calibration_by_side_bins.csv")

agg <- by_side %>% filter(model == "v2.1 as shipped")
lab <- function(s) agg %>% filter(side == s)
cal_bins <- cal_bins %>% mutate(nudge = ifelse(side == "Away team favored", 0.004, -0.004))   # keep overlapping bars apart
p1 <- ggplot(cal_bins, aes(claimed, won, colour = side)) +
  geom_abline(slope = 1, intercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.8) +
  geom_errorbar(aes(x = claimed + nudge, ymin = lo, ymax = hi), width = 0, linewidth = 0.8) +
  geom_point(aes(x = claimed + nudge), size = 2.4) +
  facet_wrap(~model) +
  scale_colour_manual(values = c("Home team favored" = cs_pal[["blue"]], "Away team favored" = cs_pal[["orange"]])) +
  scale_x_continuous(labels = scales::percent, limits = c(0.5, 1)) +
  scale_y_continuous(labels = scales::percent, breaks = seq(0.3, 1, 0.1)) +
  labs(title = sprintf("v2.1's away-favorite forecasts claimed %.0f%% and won %.0f%%; the season average hid it",
                       100 * lab("Away team favored")$claimed, 100 * lab("Away team favored")$won),
       subtitle = sprintf(paste0("Claimed confidence in the favored team against how often it won, by side, with 95%% Wilson intervals.\n",
                                 "Across all v2.1 forecasts the two cancel: claimed %.1f%%, won %.1f%%."),
                          100 * lab("All forecasts")$claimed, 100 * lab("All forecasts")$won),
       x = "Claimed confidence (bin average)", y = "Favored team won",
       caption = paste0("2025-26 holdout backtest: ", format(nrow(f), big.mark = ","),
                        " D1 games, KenPom snapshot as of each game day, v2.2 fit out of fold.", src)) +
  theme_cs()
save_fig(p1, fig("01_calibration_by_side.png"), width = 9, height = 5)

# patch or replace? paired Brier differences
pr <- bind_rows(
  tibble(comparison = "v2.1 as shipped minus v2.1 with the table on both sides (the patch)",
         x = brier_i(f$p_v21, f$home_win) - brier_i(f$p_v21_sym, f$home_win)),
  tibble(comparison = "v2.1 with the table on both sides minus v2.2 (the replacement)",
         x = brier_i(f$p_v21_sym, f$home_win) - brier_i(f$p_v22, f$home_win)),
  tibble(comparison = "v2.1 as shipped minus v2.2 (total)",
         x = brier_i(f$p_v21, f$home_win) - brier_i(f$p_v22, f$home_win))) %>%
  group_by(comparison) %>%
  summarise(n = n(), brier_gain = mean(x), lo = boot_mean(x, B)[["lo"]], hi = boot_mean(x, B)[["hi"]], .groups = "drop")
briers <- tibble(model = c("v2.1 as shipped", "v2.1, table applied to both sides", "v2.2", "KenPom FanMatch"),
                 brier = c(mean(brier_i(f$p_v21, f$home_win)), mean(brier_i(f$p_v21_sym, f$home_win)),
                           mean(brier_i(f$p_v22, f$home_win)), mean(brier_i(f$p_fanmatch, f$home_win))), n = nrow(f))
res(pr, "patch_vs_replace.csv"); res(briers, "brier_by_model.csv")
print(pr, width = 200); print(briers)

# ---- 2. conference-tournament fatigue penalty with its sign reversed ----------------------------------
ct <- ct %>% mutate(resid = margin - margin_v22,
                    fat_diff = as.integer(away_4d >= 2) - as.integer(home_4d >= 2),   # + = away team tired
                    b2b_diff = away_b2b - home_b2b)
tired_resid <- function(d, col) {     # residual from the tired team's side, games where exactly one team is tired
  one <- d %>% filter(.data[[col]] != 0)
  r <- ifelse(one[[col]] > 0, -one$resid, one$resid)
  b <- boot_mean(r, B)
  tibble(n = nrow(one), est = b[["est"]], se = sd(r) / sqrt(length(r)), lo = b[["lo"]], hi = b[["hi"]])
}
pen_games <- ct %>% filter(pen_intended != 0)
# the penalty from the tired team's side (as designed, it lowers the tired team's margin)
tired_side_pen <- function(d) {
  d <- d %>% filter(fat_diff != 0)
  ifelse(d$fat_diff > 0, -d$pen_intended, d$pen_intended)
}
design <- tired_side_pen(ct)
fatigue <- bind_rows(
  tibble(row = "Penalty as designed", kind = "Assumed", n = length(design), est = mean(design), se = NA, lo = NA, hi = NA),
  tibble(row = "Penalty as applied (sign reversed)", kind = "Assumed", n = length(design), est = -mean(design), se = NA, lo = NA, hi = NA),
  tired_resid(ct, "fat_diff") %>% mutate(row = "Measured: 2+ games in the prior 4 days\n(the penalty's own trigger)", kind = "Measured"),
  tired_resid(ct, "b2b_diff") %>% mutate(row = "Measured: played yesterday,\nopponent did not", kind = "Measured"))
coef_pen <- summary(lm(resid ~ pen_intended, data = ct))$coefficients["pen_intended", ]
brier_ct <- ct %>% transmute(none = brier_i(pnorm(margin_v22 / 10.8), home_win),
                             intended = brier_i(pnorm((margin_v22 + pen_intended) / 10.8), home_win),
                             as_applied = brier_i(pnorm((margin_v22 + pen_as_applied) / 10.8), home_win))
fat_summary <- tibble(
  games = nrow(ct), seasons = paste(range(ct$season), collapse = "-"),
  games_with_penalty = nrow(pen_games), games_with_penalty_2025_26 = sum(pen_games$season == 2026),
  conf_tournament_games_2025_26 = sum(ct$season == 2026),
  penalty_coefficient = coef_pen[["Estimate"]], penalty_coefficient_se = coef_pen[["Std. Error"]],
  brier_none = mean(brier_ct$none), brier_intended = mean(brier_ct$intended), brier_as_applied = mean(brier_ct$as_applied),
  brier_as_applied_minus_none = mean(brier_ct$as_applied - brier_ct$none),
  lo = boot_mean(brier_ct$as_applied - brier_ct$none, B)[["lo"]], hi = boot_mean(brier_ct$as_applied - brier_ct$none, B)[["hi"]])
res(fatigue %>% mutate(row = gsub("\n", " ", row)), "fatigue_penalty_vs_evidence.csv"); res(fat_summary, "fatigue_summary.csv")
print(fatigue, width = 200); print(fat_summary, width = 200)

fatigue$row <- factor(fatigue$row, levels = rev(fatigue$row))
p2 <- ggplot(fatigue, aes(est, row, colour = kind)) +
  geom_vline(xintercept = 0, colour = cs_ink[["baseline"]], linewidth = 0.8) +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0.15, orientation = "y", linewidth = 0.8, na.rm = TRUE) +
  geom_point(size = 2.8) +
  geom_label(aes(label = sprintf("%+.2f", est)), vjust = -0.6, size = 3.3, fill = cs_ink[["surface"]],
             border.colour = NA, label.padding = unit(0.1, "lines"), show.legend = FALSE) +
  scale_colour_manual(values = c(Assumed = cs_pal[["orange"]], Measured = cs_pal[["blue"]])) +
  scale_x_continuous(limits = c(-3, 3)) +
  labs(title = "The fatigue penalty pushed margins the wrong way, and its trigger had no measurable effect",
       subtitle = "Points added to a tired team's margin (assumed) or by which it beat v2.2's margin (measured, 95% bootstrap\nintervals). Games where exactly one team was tired.",
       x = "Points for the tired team", y = NULL,
       caption = paste0("Conference tournaments 2022-23 to 2025-26: ", format(nrow(ct), big.mark = ","),
                        " games, KenPom snapshot as of each game day.", src)) +
  theme_cs() + theme(plot.title = element_text(size = rel(1.05)))
save_fig(p2, fig("02_fatigue_penalty.png"), width = 9, height = 4.8)

# ---- 3. evaluation records: self-referential spread grading, 0-0 games, ungraded pushes ---------------
picks <- dbGetQuery(arch, "
  SELECT ap.pick_id, ap.game_id, ap.spread_line_at_pick AS stored, ph.predicted_spread AS model
  FROM agent_picks ap LEFT JOIN prediction_history ph ON ph.game_id = ap.game_id AND ph.prediction_date = ap.pick_date")
snaps <- dbGetQuery(arch, "SELECT game_id, consensus_spread AS home_line FROM consensus_odds WHERE consensus_spread IS NOT NULL")
match <- picks %>% left_join(snaps, by = "game_id", relationship = "many-to-many") %>%
  group_by(pick_id) %>%
  summarise(own = any(!is.na(model) & abs(stored - model) < 0.01),
            backwards = any(!is.na(home_line) & abs(stored - home_line) < 0.01),
            right_way = any(!is.na(home_line) & abs(stored + home_line) < 0.01), .groups = "drop")
line_source <- match %>%
  mutate(source = case_when(
    own ~ "The model's own predicted margin",
    backwards ~ "A market line, stored with the sign the grader reads backwards",
    right_way ~ "A market line, stored with the sign the grader expects",
    TRUE ~ "Could not be traced to the model or a stored line")) %>%
  count(source, name = "tracked_calls") %>% mutate(share = tracked_calls / sum(tracked_calls)) %>% arrange(desc(tracked_calls))
res(line_source, "spread_tracking_line_source.csv"); print(line_source)

zero <- dbGetQuery(arch, "
  SELECT COUNT(*) AS graded_predictions,
         SUM(CASE WHEN g.home_score = 0 AND g.away_score = 0 THEN 1 ELSE 0 END) AS graded_on_0_0_games,
         SUM(CASE WHEN g.home_score = 0 AND g.away_score = 0 AND ph.actual_winner_id = g.away_team_id THEN 1 ELSE 0 END)
           AS recorded_as_away_wins
  FROM prediction_history ph JOIN games g USING (game_id) WHERE ph.correct IS NOT NULL")
zero_status <- dbGetQuery(arch, "SELECT status, COUNT(*) AS games FROM games
                                 WHERE season = 2026 AND home_score = 0 AND away_score = 0 GROUP BY status")
pushes <- dbGetQuery(arch, "
  SELECT COUNT(*) AS counted_as_push_before_fix,
         SUM(CASE WHEN actual_winner IS NOT NULL THEN 1 ELSE 0 END) AS counted_as_push_after_fix,
         SUM(CASE WHEN actual_winner IS NULL THEN 1 ELSE 0 END) AS never_graded
  FROM agent_picks WHERE spread_line_at_pick IS NOT NULL AND spread_correct IS NULL")
grading <- bind_cols(zero, pushes, tibble(postponed_or_canceled_0_0_games = sum(zero_status$games)))
res(grading, "grading_defects.csv"); print(grading)

line_source$source <- factor(line_source$source, levels = rev(line_source$source))
p3 <- ggplot(line_source, aes(tracked_calls, source)) +
  geom_col(fill = cs_pal[["blue"]], width = 0.6) +
  geom_text(aes(label = sprintf("%d (%.0f%%)", tracked_calls, 100 * share)), hjust = -0.1, size = 3.4,
            colour = cs_ink[["secondary"]]) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.18))) +
  scale_y_discrete(labels = function(x) gsub(", stored", ",\nstored", x)) +
  labs(title = sprintf("%.0f%% of last season's tracked spread calls were graded against the wrong number",
                       100 * sum(line_source$share[grepl("own|backwards", line_source$source)])),
       subtitle = "Where the line each tracked call was graded against came from, 2025-26",
       x = "Tracked spread calls", y = NULL,
       caption = paste0("2025-26: ", format(sum(line_source$tracked_calls), big.mark = ","),
                        " tracked calls. The results of those calls are deliberately not shown.", src)) +
  theme_cs() + theme(panel.grid.major.y = element_blank())
save_fig(p3, fig("03_spread_tracking_line_source.png"), width = 9, height = 4)

# ---- 4. the model-vs-market disagreement field (spread_value) and the live margin scale ---------------
live <- dbGetQuery(arch, "
  WITH first AS (
    SELECT game_id, consensus_spread FROM (
      SELECT game_id, consensus_spread, ROW_NUMBER() OVER (PARTITION BY game_id ORDER BY snapshot_time) AS rn
      FROM consensus_odds WHERE consensus_spread IS NOT NULL) WHERE rn = 1)
  SELECT ph.predicted_spread AS model, f.consensus_spread AS market_home_line, g.home_score - g.away_score AS margin
  FROM prediction_history ph JOIN games g USING (game_id) LEFT JOIN first f USING (game_id)
  WHERE g.home_score + g.away_score > 0")
wl <- live %>% filter(!is.na(market_home_line)) %>%
  mutate(market = -market_home_line, field_shipped = model - market_home_line, field_intended = model - market)
sv <- tibble(
  games_with_line = nrow(wl),
  sign_wrong_share = mean(sign(wl$field_shipped) != sign(wl$field_intended) & wl$field_intended != 0) /
    mean(wl$field_intended != 0),
  corr_with_intended = cor(wl$field_shipped, wl$field_intended),
  corr_with_market_margin = cor(wl$field_shipped, wl$market),
  flagged_2plus_shipped = mean(abs(wl$field_shipped) >= 2), flagged_2plus_intended = mean(abs(wl$field_intended) >= 2))
res(sv, "disagreement_field_sign.csv"); print(sv, width = 200)

slope0 <- function(x, y) sum(x * y) / sum(x * x)
set.seed(4)
boot_sl <- function(x, y) quantile(vapply(seq_len(B), function(i) { j <- sample.int(length(x), replace = TRUE); slope0(x[j], y[j]) },
                                          numeric(1)), c(0.025, 0.975))
lv <- live %>% filter(!is.na(model))
ci_all <- boot_sl(lv$model, lv$margin); ci_wl <- boot_sl(wl$model, wl$margin)
scale_tab <- tibble(
  sample = c("All graded live predictions", "Live predictions with a market line"),
  n = c(nrow(lv), nrow(wl)),
  slope_actual_on_predicted = c(slope0(lv$model, lv$margin), slope0(wl$model, wl$margin)),
  lo = c(ci_all[[1]], ci_wl[[1]]), hi = c(ci_all[[2]], ci_wl[[2]]),
  rmse_predicted = c(sqrt(mean((lv$margin - lv$model)^2)), sqrt(mean((wl$margin - wl$model)^2))),
  rmse_market = c(NA, sqrt(mean((wl$margin - wl$market)^2))),
  sd_predicted = c(sd(lv$model), sd(wl$model)), sd_market = c(NA, sd(wl$market)))
res(scale_tab, "live_margin_scale.csv"); print(scale_tab, width = 200)

# ---- 5. the inventory, ordered by severity --------------------------------------------------------------
pct <- function(x) sprintf("%.0f%%", 100 * x)
away <- by_side %>% filter(model == "v2.1 as shipped", side == "Away team favored")
wrong <- sum(line_source$share[grepl("own|backwards", line_source$source)])
inventory <- tribble(
  ~defect, ~severity, ~scope, ~measured_impact, ~found_by, ~fix, ~guard_now,
  "Self-referential spread evaluation", "High", sprintf("All %s tracked spread calls", format(sum(line_source$tracked_calls), big.mark = ",")),
  sprintf("%s graded against the model's own margin or a sign-reversed line; the side followed the straight-up winner call", pct(wrong)),
  "Tracing the metric from grader back to the stored line", "Store the market home margin; no line, no call; side from model margin vs line",
  "One documented sign convention in the code; no unit test yet",
  "Calibration table applied only when the home team was favored", "High", sprintf("%s of %s games (v2.1 favored the away team)", format(away$n, big.mark = ","), format(nrow(f), big.mark = ",")),
  sprintf("Away-favorite forecasts claimed %.1f%%, won %.1f%%; Brier %.4f vs %.4f for v2.2", 100 * away$claimed, 100 * away$won,
          briers$brier[1], briers$brier[3]),
  "Holdout backtest, calibration split by side", "Replaced by v2.2 (symmetric by construction)", "Backtest report prints calibration by side",
  "Live margins about twice real margins", "Medium", sprintf("%s graded live predictions", format(scale_tab$n[1], big.mark = ",")),
  sprintf("Slope of actual on predicted %.2f (95%% CI %.2f to %.2f)", scale_tab$slope_actual_on_predicted[1], scale_tab$lo[1], scale_tab$hi[1]),
  "Slope of actual margin on predicted margin (this study)", "Replaced by v2.2's margin in points", "Margin slope tracked by period in the research notes",
  "Model-vs-market disagreement field with its sign reversed", "Medium", sprintf("%s games with a line (report field)", format(sv$games_with_line, big.mark = ",")),
  sprintf("Reported side wrong in %s of games; field correlated %.2f with the market's own margin", pct(sv$sign_wrong_share), sv$corr_with_market_margin),
  "Sign-convention audit while building the side-by-side slate", "Sign fixed; conventions written beside the code", "Slate shows model, KenPom and market margins side by side",
  "Conference-tournament fatigue penalty with its sign reversed", "Medium", sprintf("%d of %d conference-tournament games in 2025-26", fat_summary$games_with_penalty_2025_26,
                                                                            fat_summary$conf_tournament_games_2025_26),
  sprintf("Moved margins %.2f points the wrong way; Brier change %+.4f (not distinguishable from zero)", mean(design) * -1, fat_summary$brier_as_applied_minus_none),
  "Code review of sign conventions, then a residual test on 1,189 games", "Removed; a tested 1.9-point back-to-back adjustment replaced it", "New adjustments need a leave-one-season-out test",
  "Postponed 0-0 games graded as results", "Low", sprintf("%d of %s graded predictions", grading$graded_on_0_0_games, format(grading$graded_predictions, big.mark = ",")),
  "Every one recorded as an away win", "Data validation: status field vs score", "Grade only when the score is not 0-0", "Status command counts stale ungraded games",
  "Ungraded calls counted as pushes", "Low", sprintf("%d calls in 2025-26", grading$counted_as_push_before_fix),
  sprintf("Pushes overstated %d vs %d; on 2026-11-05 all 43 ungraded calls showed as pushes", grading$counted_as_push_before_fix, grading$counted_as_push_after_fix),
  "Workspace review of the day's tracking summary", "A push must be graded, have a line and no result", "None beyond the fixed query")
res(inventory, "defect_inventory.csv")
cat("done\n")
