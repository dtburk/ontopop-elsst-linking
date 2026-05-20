#!/usr/bin/env Rscript
# Phase 1: deterministic string matching (exact and stemmed).
#
# Run from the project root:
#   Rscript scripts/02_string_match.R
#
# Outputs:
#   data/candidates_exact.rds  — candidate pairs from Phase 1
#   data/candidates_exact.csv  — same, for inspection

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(SnowballC)
  library(readr)
})

source("R/normalize.R")
source("R/extract_gloss.R")

dir.create("data", showWarnings = FALSE)

# ── Load cached tables ────────────────────────────────────────────────────────
elsst   <- readRDS("data/cache/elsst.rds")
ontopop <- readRDS("data/cache/ontopop.rds")

# ── Enrich OntoPop with per-concept gloss ─────────────────────────────────────
# definedInContext is shared across sibling terms; extract only the bullet
# that belongs to each specific code.
message("Extracting per-concept glosses from OntoPop definedInContext ...")
ontopop <- ontopop |>
  mutate(gloss_en = extract_gloss_en(code, definition_en))

saveRDS(ontopop, "data/cache/ontopop.rds")  # update cache with new column
message(sprintf("  gloss_en extracted for %d / %d classes",
                sum(!is.na(ontopop$gloss_en)), nrow(ontopop)))

# ── Build label pools (one row per label per concept) ─────────────────────────
# OntoPop pool
ontopop_pool <- bind_rows(
  ontopop |>
    filter(!is.na(pref_en)) |>
    transmute(ontopop_id = id, ontopop_code = code, ontopop_pref_en = pref_en,
              label = pref_en, label_type = "pref"),
  ontopop |>
    filter(lengths(alt_en) > 0) |>
    select(ontopop_id = id, ontopop_code = code, ontopop_pref_en = pref_en,
           alt_en) |>
    unnest(alt_en) |>
    rename(label = alt_en) |>
    mutate(label_type = "alt")
) |>
  mutate(label_norm = normalize_label(label),
         label_stem = stem_label(label_norm))

# ELSST pool
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
  mutate(label_norm = normalize_label(label),
         label_stem = stem_label(label_norm))

message(sprintf("OntoPop label pool: %d rows (%d concepts)",
                nrow(ontopop_pool), n_distinct(ontopop_pool$ontopop_id)))
message(sprintf("ELSST label pool:   %d rows (%d concepts)",
                nrow(elsst_pool),   n_distinct(elsst_pool$elsst_id)))

# ── Tier 1: exact normalised match ────────────────────────────────────────────
do_join <- function(op, ep, by_col, tier_label) {
  inner_join(
    op |> select(ontopop_id, ontopop_code, ontopop_pref_en,
                 ontopop_label = label, ontopop_label_type = label_type,
                 join_key = {{ by_col }}),
    ep |> select(elsst_id, elsst_uuid, elsst_pref_en,
                 elsst_label = label, elsst_label_type = label_type,
                 join_key = {{ by_col }}),
    by = "join_key",
    relationship = "many-to-many"
  ) |>
    select(-join_key) |>
    mutate(match_tier = tier_label,
           match_source = paste0(tier_label, ":",
                                 ontopop_label_type, "-", elsst_label_type))
}

tier1 <- do_join(ontopop_pool, elsst_pool, label_norm, "exact")

# ── Tier 2: stemmed match (only for OntoPop terms not already in tier 1) ──────
matched_op_ids <- unique(tier1$ontopop_id)
ontopop_pool_rem <- filter(ontopop_pool, !ontopop_id %in% matched_op_ids)

tier2 <- do_join(ontopop_pool_rem, elsst_pool, label_stem, "stem")

# ── Combine and flag ambiguous matches ────────────────────────────────────────
candidates <- bind_rows(tier1, tier2) |>
  group_by(ontopop_id) |>
  mutate(ambiguous = n_distinct(elsst_id) > 1) |>
  ungroup() |>
  arrange(ontopop_code, match_tier, ontopop_label_type, elsst_label_type)

# ── Summary ───────────────────────────────────────────────────────────────────
cat("\n=== Phase 1 results ===\n")
cat("Total candidate pairs:          ", nrow(candidates), "\n")
cat("Distinct OntoPop terms matched: ",
    n_distinct(candidates$ontopop_id), "/",
    sum(!is.na(ontopop$pref_en)), "\n")
cat("Distinct ELSST terms matched:   ",
    n_distinct(candidates$elsst_id), "/", nrow(elsst), "\n")

cat("\nBy tier:\n")
candidates |>
  count(match_tier, match_source) |>
  as.data.frame() |>
  print()

cat("\nAmbiguous OntoPop matches (multiple ELSST candidates):\n")
candidates |>
  filter(ambiguous) |>
  distinct(ontopop_code, ontopop_pref_en) |>
  as.data.frame() |>
  print()

# ── Save ──────────────────────────────────────────────────────────────────────
saveRDS(candidates, "data/candidates_exact.rds")
write_csv(candidates, "data/candidates_exact.csv")
cat("\nSaved to data/candidates_exact.rds and data/candidates_exact.csv\n")
