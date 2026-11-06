# Download and cache every public dataset the studies use (data/cache/, gitignored). Safe to re-run.
#   Rscript scripts/warm_cache.R
source("R/data.R")
t0 <- Sys.time()
g <- cbb_games(2002:2026);       cat("games:", nrow(g), "\n")
t <- cbb_team_box(2008:2026);    cat("team box:", nrow(t), "\n")
p <- cbb_player_box(2010:2026);  cat("player box:", nrow(p), "\n")
cat("done in", round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), "min\n")
