# Rscript tests/test_ratings.R   (from the repo root) -> prints "ok"
source("R/ratings.R")
set.seed(7)
k <- 60
true <- setNames(rnorm(k, 0, 8), sprintf("t%02d", seq_len(k)))
pairs <- t(replicate(3000, sample(names(true), 2)))
neutral <- rbinom(nrow(pairs), 1, 0.15)
games <- tibble::tibble(
  home_id = pairs[, 1], away_id = pairs[, 2], neutral = neutral,
  margin = true[pairs[, 1]] - true[pairs[, 2]] + 3.5 * (1 - neutral) + rnorm(nrow(pairs), 0, 10),
  date = as.Date("2026-01-01") + sample(0:90, nrow(pairs), replace = TRUE),
  home_d1 = TRUE, away_d1 = TRUE
)
# one non-D1 opponent that must not get a rating
games <- dplyr::bind_rows(games, tibble::tibble(home_id = "t01", away_id = "nond1", neutral = 0, margin = 40,
                                                date = as.Date("2026-01-05"), home_d1 = TRUE, away_d1 = FALSE))
fit <- fit_ratings(games)
est <- setNames(fit$ratings$rating, fit$ratings$team_id)[names(true)]
stopifnot(abs(fit$hca - 3.5) < 0.3)
stopifnot(cor(true, est) > 0.98)
stopifnot(!"nond1" %in% fit$ratings$team_id)
stopifnot(abs(mean(fit$ratings$rating)) < 1e-8)
early <- fit_ratings(games, before = "2026-02-01")
stopifnot(early$n_games < fit$n_games, all(is.finite(early$ratings$rating)))
p <- predict_margin(fit, "t01", "t02", neutral = 1)
stopifnot(abs(p - (est[["t01"]] - est[["t02"]])) < 1e-8, is.na(predict_margin(fit, "t01", "zzz")))
cat("ok\n")
