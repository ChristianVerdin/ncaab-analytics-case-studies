# NN. Title as a plain question or claim

**The answer, in two sentences.** Lead with the finding and its size, with uncertainty: "X is about 3.1 points (95% CI 2.8 to 3.4)".

| | |
|---|---|
| **Question** | One sentence. |
| **Data** | Sources, seasons, number of games or teams. Public (ESPN via hoopR) or private (KenPom, aggregates only). |
| **Method** | One line, e.g. "Ridge ratings fit on games before each date, residuals regressed on rest, leave-one-season-out". |
| **Skills shown** | e.g. calibration, causal inference, clustering, data engineering, LLM evaluation. |

## Why it matters
Two or three sentences for a non-specialist: why anyone deciding anything would care.

## What I found
Numbered findings. Each has one figure or table with the numbers, and one sentence on how to read it.

![Figure title](figures/01_name.png)

*How to read it: one sentence.* The figure's numbers are in `results/<name>.csv`.

## How I checked it
Robustness: holdout seasons, alternative definitions, placebo tests, simulations. Say what would have changed the conclusion.

## Limitations
What this can't tell you, and what data would fix it.

## What I'd do next
Two or three concrete next steps.

## Reproduce
```bash
Rscript studies/NN-slug/analysis.R     # from the repo root; public data, cached under data/
```
Say which parts need private data (a KenPom subscription), if any. Runtime: about N minutes.
