# Install the R packages the studies use (R 4.3+).   Rscript install.R
pkgs <- c("hoopR", "dplyr", "tidyr", "ggplot2", "Matrix", "glmnet", "cluster", "broom", "scales", "jsonlite", "readr")
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing)) install.packages(missing, repos = "https://cloud.r-project.org")
cat("ok:", paste(pkgs, collapse = ", "), "\n")
