# Public ratings model: ridge least squares on game margins.
#   margin = rating_home - rating_away + hca * (1 - neutral) + error
# Ratings are points above an average D1 team on a neutral floor. The ridge penalty (lambda) applies to team
# ratings only, never to home-court advantage, and keeps early-season fits from blowing up. Fit only on games
# before a date (before =) to avoid look-ahead.
suppressPackageStartupMessages({
  library(dplyr)
  library(Matrix)
})

fit_ratings <- function(games, before = NULL, lambda = 1, cap = Inf, d1 = TRUE) {
  g <- games
  if (d1) g <- g %>% filter(home_d1, away_d1)
  if (!is.null(before)) g <- g %>% filter(date < as.Date(before))
  g <- g %>% filter(!is.na(margin))
  if (nrow(g) == 0) stop("no games to fit")
  teams <- sort(unique(c(g$home_id, g$away_id)))
  n <- nrow(g)
  k <- length(teams)
  hi <- match(g$home_id, teams)
  ai <- match(g$away_id, teams)
  X <- sparseMatrix(i = rep(seq_len(n), 3), j = c(hi, ai, rep(k + 1, n)),
                    x = c(rep(1, n), rep(-1, n), 1 - g$neutral), dims = c(n, k + 1))
  y <- pmax(pmin(g$margin, cap), -cap)
  penalty <- Diagonal(k + 1, c(rep(lambda, k), 0))
  b <- as.numeric(solve(crossprod(X) + penalty, crossprod(X, y)))
  r <- b[seq_len(k)]
  resid <- y - as.numeric(X %*% b)
  list(
    ratings = tibble(team_id = teams, rating = r - mean(r), games = tabulate(c(hi, ai), k)),
    hca = b[k + 1],
    sigma = sd(resid),
    n_games = n
  )
}

#' Predicted home margin; NA for a team the fit has never seen.
predict_margin <- function(fit, home_id, away_id, neutral = 0) {
  r <- setNames(fit$ratings$rating, fit$ratings$team_id)
  unname(r[as.character(home_id)] - r[as.character(away_id)] + fit$hca * (1 - neutral))
}
