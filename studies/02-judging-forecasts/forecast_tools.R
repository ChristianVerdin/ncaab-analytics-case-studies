# Shared by studies 01, 02 and 10: private inputs and forecast-scoring helpers.
#
# Private inputs are per-game forecasts built from KenPom and betting-market data. They are exported from the
# private pipeline into a directory outside the repo and never committed; studies publish aggregates only.
#   CS_PRIVATE_DIR      where the exports go (default: this R session's temp dir, so nothing persists)
#   NCAAB_PRIVATE_REPO  the private pipeline (default ~/projects/ncaab_2027)
#   NCAAB_PYTHON        its Python (default <private repo>/.venv/bin/python3)
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

private_repo <- function() path.expand(Sys.getenv("NCAAB_PRIVATE_REPO", "~/projects/ncaab_2027"))

private_dir <- function() {
  d <- Sys.getenv("CS_PRIVATE_DIR", file.path(tempdir(), "cs_private"))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  normalizePath(d)
}

# Path to a private export, running its exporter (a .py file in a study folder) if the file is missing.
private_export <- function(file, exporter) {
  path <- file.path(private_dir(), file)
  if (!file.exists(path)) {
    py <- Sys.getenv("NCAAB_PYTHON", file.path(private_repo(), ".venv", "bin", "python3"))
    if (!file.exists(py)) stop("private data needed: set NCAAB_PRIVATE_REPO / NCAAB_PYTHON (KenPom subscription)")
    status <- system2(py, c(shQuote(exporter), "--private-repo", shQuote(private_repo()), "--out", shQuote(private_dir())),
                      env = "PYTHONDONTWRITEBYTECODE=1")
    if (status != 0 || !file.exists(path)) stop("export failed: ", exporter)
  }
  path
}

load_forecasts <- function() {
  path <- private_export("forecasts_2026.csv", file.path(cs_root(), "studies", "02-judging-forecasts", "export_forecasts.py"))
  read_csv(path, show_col_types = FALSE,
           col_types = cols(game_id = "c", home_team_id = "c", away_team_id = "c", fold = "c", game_date = "D"))
}

# ---- scoring -----------------------------------------------------------------------------------------------
clip <- function(p) pmin(pmax(p, 1e-6), 1 - 1e-6)
brier_i <- function(p, y) (p - y)^2
logloss_i <- function(p, y) -(y * log(clip(p)) + (1 - y) * log(1 - clip(p)))

# Percentile bootstrap of the mean of x (or of a paired difference already in x). Fixed seed per call.
boot_mean <- function(x, B = 2000, seed = 1) {
  set.seed(seed)
  n <- length(x)
  m <- vapply(seq_len(B), function(i) mean(x[sample.int(n, n, replace = TRUE)]), numeric(1))
  c(est = mean(x), lo = unname(quantile(m, 0.025)), hi = unname(quantile(m, 0.975)), se = sd(m))
}

# Weighted pool-adjacent-violators: isotonic (non-decreasing) fit of y on p, ties in p pooled first.
pav <- function(p, y) {
  u <- sort(unique(p))
  idx <- match(p, u)
  w <- tabulate(idx, length(u))
  v <- as.numeric(tapply(y, factor(idx, levels = seq_along(u)), mean))
  # stack of blocks: value, weight, number of unique points
  m <- length(u)
  bv <- numeric(m); bw <- numeric(m); bn <- integer(m); k <- 0L
  for (i in seq_len(m)) {
    k <- k + 1L; bv[k] <- v[i]; bw[k] <- w[i]; bn[k] <- 1L
    while (k > 1L && bv[k - 1L] > bv[k]) {
      bv[k - 1L] <- (bv[k - 1L] * bw[k - 1L] + bv[k] * bw[k]) / (bw[k - 1L] + bw[k])
      bw[k - 1L] <- bw[k - 1L] + bw[k]
      bn[k - 1L] <- bn[k - 1L] + bn[k]
      k <- k - 1L
    }
  }
  rep(bv[seq_len(k)], bn[seq_len(k)])[idx]
}

# CORP decomposition of the Brier score (Dimitriadis, Gneiting and Jordan 2021): Brier = MCB - DSC + UNC, exactly.
# MCB (miscalibration) = Brier(p) - Brier(recalibrated p); DSC (discrimination) = UNC - Brier(recalibrated p);
# UNC = Brier of the base rate. Recalibration is the isotonic fit of y on p.
corp <- function(p, y) {
  r <- pav(p, y)
  bs <- mean((p - y)^2); bs_r <- mean((r - y)^2); unc <- mean((mean(y) - y)^2)
  c(brier = bs, mcb = bs - bs_r, dsc = unc - bs_r, unc = unc)
}

wilson <- function(k, n, z = 1.96) {
  p <- k / n
  centre <- (p + z^2 / (2 * n)) / (1 + z^2 / n)
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / (1 + z^2 / n)
  cbind(lo = centre - half, hi = centre + half)
}

# Spread direct-label positions so no two are closer than `gap` (keeps their order and mean).
spread_labels <- function(y, gap) {
  o <- order(y); ys <- y[o]
  if (length(ys) > 1) for (i in 2:length(ys)) if (ys[i] - ys[i - 1] < gap) ys[i] <- ys[i - 1] + gap
  out <- y; out[o] <- ys - (mean(ys) - mean(y)); out
}
