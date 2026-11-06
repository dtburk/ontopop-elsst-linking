#!/usr/bin/env Rscript
# Phase 3: semantic candidate generation via embeddings.
#
# Embeds `pref_en + definition/gloss + hierarchy context` for every concept on
# both sides with OpenAI text-embedding-3-small, takes cosine top-k ELSST
# concepts per OntoPop term (all labelled terms — change 2), and merges those
# with the Phase 1 label matches and Phase 2 fuzzy candidates into one
# shortlist for Phase 4, tagged by provenance.
#
# Run from the project root (needs OPENAI_API_KEY):
#   Rscript scripts/05_embed_match.R
#
# Outputs:
#   data/cache/emb_elsst.rds     — ELSST embeddings (resumable cache)
#   data/cache/emb_ontopop.rds   — OntoPop embeddings (resumable cache)
#   data/candidates_semantic.csv — raw cosine top-k pairs
#   data/candidates_phase3.csv   — merged fuzzy + semantic shortlist

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
})

source("R/hierarchy.R")   # hierarchy_labels(), used by build_embed_text()
source("R/embed.R")

dir.create("data", showWarnings = FALSE)

K      <- 10  # ELSST candidates kept per OntoPop term
N_ASC  <- 4   # nearest ascendants folded into embedding text (change 1)
N_DESC <- 12  # descendant generation cap in embedding text (95th pct ~12)

# ── Load inputs ───────────────────────────────────────────────────────────────
elsst   <- readRDS("data/cache/elsst.rds")
ontopop <- readRDS("data/cache/ontopop.rds")
exact   <- readRDS("data/candidates_exact.rds")
fuzzy   <- readRDS("data/candidates_fuzzy.rds")

# Embedding text = label + definition/gloss + hierarchy context (change 1):
# nearest-N_ASC ascendants ("Broader:") and one descendant generation
# ("Narrower:"), via build_embed_text() in R/embed.R.

# ELSST: all concepts with an English label; definition appended where present
# (only ~26% have one — the rest fall back to label + hierarchy). Ascendants
# from the broader chain, narrower_1 as the descendant generation.
elsst_e <- elsst |>
  filter(!is.na(pref_en)) |>
  mutate(text = build_embed_text(pref_en, definition_en, ascendants, narrower_1,
                                 n_asc = N_ASC, n_desc = N_DESC))

# OntoPop: ALL labelled terms (change 2 — no Phase 1 pruning), label +
# per-concept LLM gloss. Ascendants from the subClassOf chain, children as
# the descendant generation.
onto_e <- ontopop |>
  filter(!is.na(pref_en)) |>
  mutate(text = build_embed_text(pref_en, gloss_llm, ascendants, children,
                                 n_asc = N_ASC, n_desc = N_DESC))

message(sprintf("Embedding %d ELSST concepts and %d OntoPop terms (all labelled)",
                nrow(elsst_e), nrow(onto_e)))

# ── Embed (cached) ────────────────────────────────────────────────────────────
E_elsst <- cached_embeddings(elsst_e$id, elsst_e$text, "data/cache/emb_elsst.rds")
E_onto  <- cached_embeddings(onto_e$id,  onto_e$text,  "data/cache/emb_ontopop.rds")

# ── Cosine similarity and top-k ───────────────────────────────────────────────
unit <- function(M) M / sqrt(rowSums(M ^ 2))
sim  <- unit(E_onto) %*% t(unit(E_elsst))   # rows = OntoPop, cols = ELSST

semantic <- bind_rows(lapply(seq_len(nrow(sim)), function(i) {
  ord <- order(sim[i, ], decreasing = TRUE)[seq_len(K)]
  tibble(onto_row = i, elsst_row = ord, cos_sim = sim[i, ord])
})) |>
  transmute(
    ontopop_id   = onto_e$id[onto_row],
    elsst_id     = elsst_e$id[elsst_row],
    cos_sim      = cos_sim
  )

# ── Merge Phase 1 + fuzzy + semantic into one shortlist ───────────────────────
# Change 2 (iteration 2): Phase 1 exact/stem hits are folded in as a
# pre-labelled candidate source (never auto-accepted), so they are adjudicated
# in Phase 4 and reviewed in Phase 5 alongside the fuzzy/semantic candidates.
max_na <- function(x) { x <- x[!is.na(x)]; if (length(x)) max(x) else NA_real_ }

# Phase 1 pairs, one row per (ontopop_id, elsst_id), preferring the exact tier.
phase1 <- exact |>
  mutate(p1_rank = if_else(match_tier == "exact", 1L, 2L)) |>
  arrange(p1_rank) |>
  group_by(ontopop_id, elsst_id) |>
  summarise(phase1_tier = first(match_tier), .groups = "drop")

combined <- bind_rows(
  phase1   |> transmute(ontopop_id, elsst_id),
  fuzzy    |> transmute(ontopop_id, elsst_id, jw_sim),
  semantic |> transmute(ontopop_id, elsst_id, cos_sim)
) |>
  group_by(ontopop_id, elsst_id) |>
  summarise(jw_sim  = max_na(jw_sim),
            cos_sim = max_na(cos_sim),
            .groups = "drop") |>
  left_join(phase1, by = c("ontopop_id", "elsst_id")) |>
  mutate(from_phase1   = !is.na(phase1_tier),
         from_fuzzy    = !is.na(jw_sim),
         from_semantic = !is.na(cos_sim),
         provenance    = mapply(function(p, f, s)
           paste(c("phase1", "fuzzy", "semantic")[c(p, f, s)], collapse = "+"),
           from_phase1, from_fuzzy, from_semantic)) |>
  left_join(ontopop |> transmute(ontopop_id = id, ontopop_code = code,
                                 ontopop_pref_en = pref_en,
                                 ontopop_gloss = gloss_llm),
            by = "ontopop_id") |>
  left_join(elsst |> transmute(elsst_id = id, elsst_uuid = uuid,
                               elsst_pref_en = pref_en,
                               elsst_definition = definition_en),
            by = "elsst_id") |>
  arrange(ontopop_code, desc(coalesce(cos_sim, jw_sim))) |>
  select(ontopop_id, ontopop_code, ontopop_pref_en, ontopop_gloss,
         elsst_id, elsst_uuid, elsst_pref_en, elsst_definition,
         jw_sim, cos_sim, from_phase1, from_fuzzy, from_semantic,
         phase1_tier, provenance)

# ── Summary ───────────────────────────────────────────────────────────────────
cat("\n=== Phase 3 results ===\n")
cat("Semantic candidate pairs:        ", nrow(semantic), "\n")
cat("Merged shortlist pairs:          ", nrow(combined), "\n")
cat("  with Phase 1 provenance:       ", sum(combined$from_phase1), "\n")
cat("  with fuzzy provenance:         ", sum(combined$from_fuzzy), "\n")
cat("  with semantic provenance:      ", sum(combined$from_semantic), "\n")
cat("  Phase 1 only (no fuzzy/sem):    ",
    sum(combined$provenance == "phase1"), "\n")
cat("OntoPop terms with >=1 candidate: ",
    n_distinct(combined$ontopop_id), "/", nrow(onto_e), "\n")

cat("\nTop 15 semantic-only pairs by cosine similarity:\n")
combined |>
  filter(provenance == "semantic") |>
  arrange(desc(cos_sim)) |>
  transmute(ontopop_code, ontopop_pref_en, elsst_pref_en,
            cos_sim = round(cos_sim, 3)) |>
  head(15) |>
  as.data.frame() |>
  print(row.names = FALSE)

# ── Save ──────────────────────────────────────────────────────────────────────
saveRDS(semantic, "data/candidates_semantic.rds")
write_csv(semantic, "data/candidates_semantic.csv")
saveRDS(combined, "data/candidates_phase3.rds")
write_csv(combined, "data/candidates_phase3.csv")
cat("\nSaved data/candidates_semantic.csv and data/candidates_phase3.csv\n")
