# Study 12 end to end from the warm cache: build season.db, re-score the saved model outputs locally (no API calls),
# and draw the figures.
#   Rscript studies/12-ask-the-season/analysis.R      (from the repo root; ASK_PYTHON = a Python 3.11+ interpreter)
suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(readr)
})
source("R/theme.R")

study <- "studies/12-ask-the-season"
py <- Sys.getenv("ASK_PYTHON", "python3")

source(file.path(study, "build_db.R"))
status <- system2(py, file.path(study, "eval", "score.py"))
if (status != 0) stop("score.py failed")

summ <- read_csv(file.path(study, "results", "eval_summary.csv"), show_col_types = FALSE)
byq <- read_csv(file.path(study, "results", "eval_by_question.csv"), show_col_types = FALSE)

# ---- figure 1: accuracy with Wilson intervals, dev and held-out test
final_runs <- c("baseline_dev", "improved_v2_dev", "baseline_test", "improved_test")
if (!"improved_v2_dev" %in% summ$run) final_runs[2] <- "improved_v1_dev"
fig1 <- summ %>%
  filter(run %in% final_runs, subset %in% c("all", "answerable")) %>%
  mutate(prompt = ifelse(grepl("^baseline", run), "Baseline: schema only", "Improved: notes, rules, examples"),
         split = factor(ifelse(split == "dev", "Dev (tuned on)", "Test (held out)"),
                        levels = c("Dev (tuned on)", "Test (held out)")),
         subset = factor(ifelse(subset == "all", "All questions", "Answerable questions only"),
                         levels = c("All questions", "Answerable questions only")),
         label = sprintf("%d/%d", correct, n)) %>%
  select(run, prompt, split, subset, n, correct, accuracy, ci_low, ci_high, label)
write_csv(fig1, file.path(study, "results", "fig01_accuracy.csv"))

test_all <- fig1 %>% filter(split == "Test (held out)", subset == "All questions")
mc <- read_csv(file.path(study, "results", "mcnemar.csv"), show_col_types = FALSE) %>%
  filter(baseline == "baseline_test", improved == "improved_test", subset == "all")
title1 <- sprintf("Column notes and rules lifted held-out accuracy from %.0f%% to %.0f%%",
                  100 * test_all$accuracy[grepl("^Baseline", test_all$prompt)],
                  100 * test_all$accuracy[grepl("^Improved", test_all$prompt)])
p1 <- ggplot(fig1, aes(x = split, y = accuracy, colour = prompt)) +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0.12, linewidth = 0.8,
                position = position_dodge(width = 0.5)) +
  geom_point(size = 3, position = position_dodge(width = 0.5)) +
  geom_text(aes(label = label), position = position_dodge(width = 0.5), vjust = -0.2, hjust = -0.35,
            size = 3.2, show.legend = FALSE) +
  facet_wrap(~subset) +
  scale_colour_manual(values = unname(cs_pal[c("blue", "orange")])) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1.05), breaks = seq(0, 1, 0.25)) +
  labs(title = title1,
       subtitle = sprintf("Claude Haiku 4.5 text-to-SQL, 95%% Wilson intervals. Test set: %d gained, %d lost (McNemar exact p = %.3f)",
                          mc$gained, mc$lost, mc$mcnemar_exact_p),
       x = NULL, y = "Questions answered correctly",
       caption = sprintf("Source: public ESPN data via hoopR, 2019-20 to 2025-26. Dev n = %d, test n = %d questions (answerable: %d and %d).\nOne call per question at temperature 0. Improved = the final (v2) prompt.",
                         fig1$n[fig1$split == "Dev (tuned on)" & fig1$subset == "All questions"][1],
                         fig1$n[fig1$split == "Test (held out)" & fig1$subset == "All questions"][1],
                         fig1$n[fig1$split == "Dev (tuned on)" & fig1$subset == "Answerable questions only"][1],
                         fig1$n[fig1$split == "Test (held out)" & fig1$subset == "Answerable questions only"][1])) +
  theme_cs()
save_fig(p1, file.path(study, "figures", "01_accuracy.png"), width = 9, height = 5)

# ---- figure 2: why answers were wrong, dev and test pooled, by prompt
fig2 <- byq %>%
  filter(run %in% final_runs, correct == 0) %>%
  mutate(prompt = ifelse(grepl("^baseline", run), "Baseline: schema only", "Improved: notes, rules, examples")) %>%
  count(prompt, failure, name = "n") %>%
  tidyr::complete(prompt, failure, fill = list(n = 0L)) %>%
  group_by(failure) %>% mutate(total = sum(n)) %>% ungroup() %>%
  arrange(desc(total), failure)
write_csv(fig2 %>% select(prompt, failure, n), file.path(study, "results", "fig02_failures.csv"))

n_base <- sum(fig2$n[grepl("^Baseline", fig2$prompt)])
n_impr <- sum(fig2$n[grepl("^Improved", fig2$prompt)])
top <- fig2 %>% filter(grepl("^Baseline", prompt), failure == "name match")
p2 <- ggplot(fig2, aes(x = n, y = reorder(failure, total))) +
  geom_col(fill = cs_pal[["blue"]], width = 0.65) +
  geom_text(aes(label = ifelse(n > 0, n, "")), hjust = -0.4, size = 3.4, colour = cs_ink[["secondary"]]) +
  facet_wrap(~prompt) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.15)), breaks = scales::breaks_pretty()) +
  labs(title = sprintf("Guessed team names or ids caused %d of the baseline's %d wrong answers", top$n, n_base),
       subtitle = sprintf("Wrong answers by cause, dev and test pooled (baseline %d of 48, final prompt %d of 48), labeled by reading each query",
                          n_base, n_impr),
       x = "Wrong answers", y = NULL,
       caption = "Source: eval/runs/*.jsonl scored by eval/score.py; labels in eval/failure_labels.csv.") +
  theme_cs() +
  theme(panel.grid.major.y = element_blank())
save_fig(p2, file.path(study, "figures", "02_failures.png"), width = 9, height = 4.8)

cat("figures written\n")
