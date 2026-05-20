#!/usr/bin/env Rscript
# Phase 3: semantic candidate generation via embeddings.
#
# Embeds `pref_en + definition` for every concept on both sides with
# OpenAI text-embedding-3-small, takes cosine top-k ELSST concepts per
# OntoPop term left unmatched by Phase 1, and merges those with the
# Phase 2 fuzzy candidates into a single shortlist for Phase 4.
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

source("R/embed.R")

dir.create("data", showWarnings = FALSE)

K <- 10  # ELSST candidates kept per OntoPop term

# ── Load inputs ───────────────────────────────────────────────────────────────
elsst   <- readRDS("data/cache/elsst.rds")
ontopop <- readRDS("data/cache/ontopop.rds")
exact   <- readRDS("data/candidates_exact.rds")
fuzzy   <- readRDS("data/candidates_fuzzy.rds")

blank_na <- function(x) ifelse(is.na(x), "", x)

# ELSST: all concepts with an English label; definition appended where present
# (only ~26% have one — the rest fall back to the label alone).
elsst_e <- elsst |>
  filter(!is.na(pref_en)) |>
  mutate(text = trimws(paste(pref_en, blank_na(definition_en))))

# OntoPop: terms left unmatched by Phase 1, label + per-concept LLM gloss.
matched_ids <- unique(exact$ontopop_id)
onto_e <- ontopop |>
  filter(!is.na(pref_en), !id %in% matched_ids) |>
  mutate(text = trimws(paste(pref_en, blank_na(gloss_llm))))

message(sprintf("Embedding %d ELSST concepts and %d unmatched OntoPop terms",
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

# ── Merge fuzzy + semantic into one shortlist ─────────────────────────────────
max_na <- function(x) { x <- x[!is.na(x)]; if (length(x)) max(x) else NA_real_ }

combined <- bind_rows(
  fuzzy    |> transmute(ontopop_id, elsst_id, jw_sim),
  semantic |> transmute(ontopop_id, elsst_id, cos_sim)
) |>
  group_by(ontopop_id, elsst_id) |>
  summarise(jw_sim  = max_na(jw_sim),
            cos_sim = max_na(cos_sim),
            .groups = "drop") |>
  mutate(from_fuzzy    = !is.na(jw_sim),
         from_semantic = !is.na(cos_sim),
         provenance    = case_when(
           from_fuzzy & from_semantic ~ "fuzzy+semantic",
           from_fuzzy                 ~ "fuzzy",
           TRUE                       ~ "semantic")) |>
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
         jw_sim, cos_sim, from_fuzzy, from_semantic, provenance)

# ── Summary ───────────────────────────────────────────────────────────────────
cat("\n=== Phase 3 results ===\n")
cat("Semantic candidate pairs:        ", nrow(semantic), "\n")
cat("Merged shortlist pairs:          ", nrow(combined), "\n")
cat("  fuzzy only:                    ", sum(combined$provenance == "fuzzy"), "\n")
cat("  semantic only:                 ", sum(combined$provenance == "semantic"), "\n")
cat("  found by both:                 ",
    sum(combined$provenance == "fuzzy+semantic"), "\n")
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
