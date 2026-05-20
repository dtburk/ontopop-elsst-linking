#!/usr/bin/env Rscript
# Phase 3 prep: extract a per-concept standalone definition from the shared
# OntoPop definedInContext paragraphs using a mid-tier LLM (one call per
# IUSSP section). Writes a `gloss_llm` column onto the cached OntoPop table.
#
# Run from the project root (needs OPENAI_API_KEY):
#   Rscript scripts/04_llm_gloss.R
#
# Outputs:
#   data/cache/gloss_llm.rds  — per-section LLM responses (resumable cache)
#   data/cache/ontopop.rds    — updated with the `gloss_llm` column
#   data/gloss_llm.csv        — code, pref_en, gloss_llm, for inspection

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(readr)
})

source("R/llm_gloss.R")

ontopop <- readRDS("data/cache/ontopop.rds")

# ── One row per section: shared paragraph + the terms defined inside it ───────
sections <- ontopop |>
  filter(!is.na(definition_en), !is.na(pref_en)) |>
  group_by(section) |>
  summarise(paragraph = strsplit(definition_en[1], "\n")[[1]][1],
            codes  = list(code),
            labels = list(pref_en),
            .groups = "drop")

message(sprintf("%d sections covering %d concepts",
                nrow(sections), sum(lengths(sections$codes))))

# ── Per-section cache (resumable: rerun skips sections already done) ──────────
cache_file <- "data/cache/gloss_llm.rds"
cache <- if (file.exists(cache_file)) readRDS(cache_file) else list()

sys_msg <- list(role = "system", content = paste(
  "You are a lexicographer extracting concise, standalone definitions of",
  "demographic terms from dictionary paragraphs. Respond only with JSON."))

todo <- which(!sections$section %in% names(cache))
message(sprintf("%d sections cached, %d to fetch", length(cache), length(todo)))

for (i in todo) {
  sec    <- sections$section[i]
  prompt <- gloss_prompt(sections$paragraph[i],
                         sections$codes[[i]], sections$labels[[i]])
  raw    <- openai_chat(list(sys_msg, list(role = "user", content = prompt)))

  defs <- fromJSON(raw)$definitions
  vec  <- setNames(as.character(defs$definition), as.character(defs$code))
  cache[[sec]] <- vec

  saveRDS(cache, cache_file)  # incremental — safe to interrupt
  message(sprintf("[%d/%d] section %s: %d / %d terms defined",
                  match(i, todo), length(todo), sec,
                  length(vec), length(sections$codes[[i]])))
}

# ── Map definitions back onto every concept by code ───────────────────────────
all_defs <- do.call(c, unname(cache))            # flat vector keyed by code
ontopop$gloss_llm <- unname(all_defs[ontopop$code])

n_have <- sum(!is.na(ontopop$gloss_llm))
n_want <- sum(!is.na(ontopop$pref_en))
cat(sprintf("\ngloss_llm populated for %d / %d concepts with an English label\n",
            n_have, n_want))
missing <- ontopop$code[is.na(ontopop$gloss_llm) & !is.na(ontopop$pref_en)]
if (length(missing) > 0)
  cat("  codes still missing a gloss:", paste(missing, collapse = ", "), "\n")

# ── Save ──────────────────────────────────────────────────────────────────────
saveRDS(ontopop, "data/cache/ontopop.rds")
ontopop |>
  filter(!is.na(pref_en)) |>
  select(code, pref_en, gloss_llm) |>
  write_csv("data/gloss_llm.csv")

cat("\nSample:\n")
ontopop |>
  filter(!is.na(gloss_llm)) |>
  slice_head(n = 6) |>
  mutate(out = sprintf("[%s] %s -> %s", code, pref_en, gloss_llm)) |>
  pull(out) |>
  writeLines()

cat("\nSaved data/cache/ontopop.rds (gloss_llm) and data/gloss_llm.csv\n")
