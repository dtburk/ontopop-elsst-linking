#!/usr/bin/env Rscript
# Phase 2: fuzzy string matching (Jaro-Winkler) for OntoPop terms left
# unmatched by Phase 1.
#
# Run from the project root:
#   Rscript scripts/03_fuzzy_match.R
#
# Outputs:
#   data/candidates_fuzzy.rds  — top-k fuzzy candidate pairs
#   data/candidates_fuzzy.csv  — same, for inspection

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
})

source("R/normalize.R")
source("R/fuzzy_match.R")

dir.create("data", showWarnings = FALSE)

# Tuning knobs.
K         <- 5     # candidates kept per OntoPop term
THRESHOLD <- 0.85  # minimum Jaro-Winkler similarity

# ── Load cached tables and Phase 1 output ─────────────────────────────────────
elsst      <- readRDS("data/cache/elsst.rds")
ontopop    <- readRDS("data/cache/ontopop.rds")
candidates <- readRDS("data/candidates_exact.rds")

# OntoPop terms still unmatched after Phase 1 (those with an English label).
matched_ids   <- unique(candidates$ontopop_id)
ontopop_unmat <- ontopop |>
  filter(!is.na(pref_en), !id %in% matched_ids)

message(sprintf("OntoPop terms unmatched after Phase 1: %d / %d",
                nrow(ontopop_unmat), sum(!is.na(ontopop$pref_en))))

# ── Build label pools (one row per label per concept) ─────────────────────────
add_keys <- function(df) {
  df |>
    filter(!is.na(label)) |>
    mutate(label_norm = normalize_label(label),
           label_sort = token_sort(label_norm)) |>
    filter(nzchar(label_norm))
}

# OntoPop pool — unmatched concepts only, pref + alt labels.
ontopop_pool <- bind_rows(
  ontopop_unmat |>
    transmute(ontopop_id = id, ontopop_code = code, ontopop_pref_en = pref_en,
              label = pref_en, label_type = "pref"),
  ontopop_unmat |>
    filter(lengths(alt_en) > 0) |>
    select(ontopop_id = id, ontopop_code = code, ontopop_pref_en = pref_en,
           alt_en) |>
    unnest(alt_en) |>
    rename(label = alt_en) |>
    mutate(label_type = "alt")
) |>
  add_keys()

# ELSST pool — full label pool, pref + alt labels.
elsst_pool <- bind_rows(
  elsst |>
    filter(!is.na(pref_en)) |>
    transmute(elsst_id = id, elsst_uuid = uuid, elsst_pref_en = pref_en,
              label = pref_en, label_type = "pref"),
  elsst |>
    filter(lengths(alt_en) > 0) |>
    select(elsst_id = id, elsst_uuid = uuid, elsst_pref_en = pref_en,
           alt_en) |>
    unnest(alt_en) |>
    rename(label = alt_en) |>
    mutate(label_type = "alt")
) |>
  add_keys()

message(sprintf("OntoPop label pool: %d rows (%d concepts)",
                nrow(ontopop_pool), n_distinct(ontopop_pool$ontopop_id)))
message(sprintf("ELSST label pool:   %d rows (%d concepts)",
                nrow(elsst_pool),   n_distinct(elsst_pool$elsst_id)))

# ── Fuzzy match ───────────────────────────────────────────────────────────────
message(sprintf("Computing Jaro-Winkler candidates (k=%d, threshold=%.2f) ...",
                K, THRESHOLD))
fuzzy <- fuzzy_candidates(ontopop_pool, elsst_pool, k = K,
                          threshold = THRESHOLD) |>
  mutate(match_tier   = "fuzzy",
         match_source = paste0("fuzzy:", ontopop_label_type, "-",
                               elsst_label_type)) |>
  group_by(ontopop_id) |>
  mutate(ambiguous = n_distinct(elsst_id) > 1) |>
  ungroup()

# ── Summary ───────────────────────────────────────────────────────────────────
cat("\n=== Phase 2 results ===\n")
cat("Total candidate pairs:          ", nrow(fuzzy), "\n")
cat("Distinct OntoPop terms matched: ",
    n_distinct(fuzzy$ontopop_id), "/", nrow(ontopop_unmat), "\n")
cat("Distinct ELSST terms matched:   ",
    n_distinct(fuzzy$elsst_id), "\n")
cat("OntoPop terms still unmatched:  ",
    nrow(ontopop_unmat) - n_distinct(fuzzy$ontopop_id), "\n")

cat("\nSimilarity distribution:\n")
print(summary(fuzzy$jw_sim))

cat("\nTop 15 candidate pairs by similarity:\n")
fuzzy |>
  arrange(desc(jw_sim)) |>
  select(ontopop_code, ontopop_label, elsst_label, jw_sim) |>
  head(15) |>
  as.data.frame() |>
  print(row.names = FALSE)

# ── Save ──────────────────────────────────────────────────────────────────────
saveRDS(fuzzy, "data/candidates_fuzzy.rds")
write_csv(fuzzy, "data/candidates_fuzzy.csv")
cat("\nSaved to data/candidates_fuzzy.rds and data/candidates_fuzzy.csv\n")
