# One look for every figure. Colors follow the validated reference palette (dataviz skill, light mode):
# categorical slots in this fixed order, never cycled; at most 3 slots on scatter-type charts. The aqua, yellow
# and magenta slots sit below 3:1 contrast on the surface, so charts using them carry direct labels or a table.
suppressPackageStartupMessages(library(ggplot2))

cs_pal <- c(blue = "#2a78d6", orange = "#eb6834", aqua = "#1baf7a",
            yellow = "#eda100", magenta = "#e87ba4", green = "#008300")
cs_ink <- c(primary = "#0b0b0b", secondary = "#52514e", muted = "#898781",
            grid = "#e1e0d9", baseline = "#c3c2b7", surface = "#fcfcfb")
cs_seq <- c("#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b")
cs_div <- c(low = "#2a78d6", mid = "#f0efec", high = "#e34948")

theme_cs <- function(base_size = 12) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.background = element_rect(fill = cs_ink[["surface"]], colour = NA),
      panel.background = element_rect(fill = cs_ink[["surface"]], colour = NA),
      panel.grid.major = element_line(colour = cs_ink[["grid"]], linewidth = 0.3),
      panel.grid.minor = element_blank(),
      axis.line.x = element_line(colour = cs_ink[["baseline"]], linewidth = 0.4),
      axis.text = element_text(colour = cs_ink[["muted"]]),
      axis.title = element_text(colour = cs_ink[["secondary"]]),
      plot.title = element_text(colour = cs_ink[["primary"]], face = "bold", size = rel(1.15)),
      plot.subtitle = element_text(colour = cs_ink[["secondary"]], margin = margin(b = 8)),
      plot.caption = element_text(colour = cs_ink[["muted"]], hjust = 0, size = rel(0.8)),
      plot.title.position = "plot",
      plot.caption.position = "plot",
      legend.position = "top",
      legend.justification = "left",
      legend.title = element_blank(),
      legend.text = element_text(colour = cs_ink[["secondary"]]),
      strip.text = element_text(colour = cs_ink[["secondary"]], face = "bold"),
      plot.margin = margin(12, 16, 10, 12)
    )
}

save_fig <- function(plot, path, width = 8, height = 5) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  ggsave(path, plot, width = width, height = height, dpi = 200, bg = cs_ink[["surface"]])
  invisible(path)
}
