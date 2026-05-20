#!/usr/bin/env Rscript
# Phase 5: build the human-review interface.
#
# Combines Phase 4 LLM-adjudicated candidates with the Phase 1 exact and
# stemmed label matches, so every OntoPop term that produced any candidate
# gets a review screen. Each candidate carries a cross-reference list of
# any OntoPop term that also exact-matched the same ELSST concept in
# Phase 1 — so when reviewing `nucleus` with NUCLEAR FAMILY as a candidate
# you can see (and jump to) the `nuclear family` review screen.
#
# Output:
#   data/review.html  (self-contained, opens in any browser)

suppressPackageStartupMessages({
  library(dplyr); library(jsonlite)
})

`%||%` <- function(a, b) if (is.null(a)) b else a
TYPES <- c("exactMatch", "closeMatch", "broadMatch",
           "narrowMatch", "relatedMatch", "none")

# ── Load all sources ──────────────────────────────────────────────────────────
exact   <- readRDS("data/candidates_exact.rds")
r4      <- readRDS("data/candidates_phase4.rds")
ontopop <- readRDS("data/cache/ontopop.rds")
elsst   <- readRDS("data/cache/elsst.rds")

elsst_def_map <- setNames(elsst$definition_en, elsst$id)
gloss_map     <- setNames(ontopop$gloss_llm,    ontopop$id)
ctx_map       <- setNames(ontopop$definition_en, ontopop$id)

# ── Partner lookup: ELSST id -> Phase 1 OntoPop term(s) that exact-match it ──
pp <- exact |> distinct(elsst_id, ontopop_code, ontopop_pref_en)
partner_lookup <- split(
  Map(function(c, l) list(code = c, label = l),
      pp$ontopop_code, pp$ontopop_pref_en),
  pp$elsst_id)

# Clean the definedInContext paragraph for display.
clean_ctx <- function(s) gsub("\\*+", "", ifelse(is.na(s), "", s))

# Build candidate objects from a row-set; filters self-references out of
# `exact_partners` so a term doesn't link to itself.
build_cands <- function(tr, current_code) {
  lapply(seq_len(nrow(tr)), function(i) {
    eid   <- tr$elsst_id[i]
    parts <- partner_lookup[[eid]]
    if (!is.null(parts))
      parts <- Filter(function(p) p$code != current_code, parts)
    list(
      elsst_id       = eid,
      elsst_label    = tr$elsst_pref_en[i],
      elsst_def      = tr$elsst_definition[i],
      match_type     = tr$match_type[i],
      rationale      = tr$rationale[i],
      jw_sim         = tr$jw_sim[i],
      cos_sim        = tr$cos_sim[i],
      provenance     = tr$provenance[i],
      tier           = tr$tier[i],
      exact_partners = parts %||% list())
  })
}

# ── Phase 4 entries (LLM-adjudicated) ─────────────────────────────────────────
r4_t <- r4 |>
  mutate(tier  = "phase4",
         rank  = match(match_type, TYPES),
         score = coalesce(cos_sim, jw_sim))

phase4_order <- r4_t |>
  group_by(ontopop_code) |>
  summarise(best = min(rank), .groups = "drop") |>
  arrange(best, ontopop_code) |>
  pull(ontopop_code)

phase4_entries <- lapply(phase4_order, function(cd) {
  tr <- r4_t |> filter(ontopop_code == cd) |> arrange(rank, desc(score))
  list(
    code       = cd,
    id         = tr$ontopop_id[1],
    label      = tr$ontopop_pref_en[1],
    gloss      = tr$ontopop_gloss[1],
    context    = clean_ctx(ctx_map[tr$ontopop_id[1]]),
    section    = "Phase 4 — LLM-adjudicated",
    cat        = "phase4",
    candidates = build_cands(tr, cd))
})

# ── Phase 1 entries (exact + stem label matches) ──────────────────────────────
p1 <- exact |>
  arrange(match_tier, match_source) |>           # prefer exact:pref-pref
  group_by(ontopop_id, elsst_id) |>
  slice(1) |>                                    # one row per concept pair
  ungroup() |>
  mutate(
    elsst_definition = elsst_def_map[elsst_id],
    match_type       = "exactMatch",             # default suggestion
    rationale        = sprintf("Phase 1 %s-tier match (%s).",
                               match_tier, match_source),
    jw_sim           = ifelse(match_tier == "exact", 1.0, NA_real_),
    cos_sim          = NA_real_,
    provenance       = paste0("phase1:", match_tier),
    tier             = paste0("phase1:", match_tier))

build_phase1 <- function(rows, section_label, cat) {
  codes <- sort(unique(rows$ontopop_code))
  lapply(codes, function(cd) {
    tr <- rows |> filter(ontopop_code == cd)
    list(
      code       = cd,
      id         = tr$ontopop_id[1],
      label      = tr$ontopop_pref_en[1],
      gloss      = unname(gloss_map[tr$ontopop_id[1]]),
      context    = clean_ctx(ctx_map[tr$ontopop_id[1]]),
      section    = section_label,
      cat        = cat,
      candidates = build_cands(tr, cd))
  })
}

p1_exact <- build_phase1(p1 |> filter(match_tier == "exact"),
                         "Phase 1 — exact label match", "phase1exact")
p1_stem  <- build_phase1(p1 |> filter(match_tier == "stem"),
                         "Phase 1 — stemmed label match (heuristic)", "phase1stem")

# ── Order: easy Phase 1 first, then Phase 4 by LLM strength, then stem ────────
terms <- c(p1_exact, phase4_entries, p1_stem)

n_cands <- sum(vapply(terms, function(t) length(t$candidates), integer(1)))
cat(sprintf(
  "Building %d terms (%d Phase 1 exact + %d Phase 4 + %d Phase 1 stem), %d pairs\n",
  length(terms), length(p1_exact), length(phase4_entries),
  length(p1_stem), n_cands))

# ── Emit JSON into the template ───────────────────────────────────────────────
json  <- toJSON(terms, auto_unbox = TRUE, na = "null")
json  <- gsub("</", "<\\/", json, fixed = TRUE)
tmpl  <- readChar("R/review_template.html",
                  file.info("R/review_template.html")$size)
parts <- strsplit(tmpl, "__REVIEW_DATA__", fixed = TRUE)[[1]]
if (length(parts) != 2) stop("placeholder __REVIEW_DATA__ not found")

writeLines(paste0(parts[1], json, parts[2]),
           "data/review.html", useBytes = TRUE)
cat(sprintf("Wrote data/review.html (%.1f MB)\n",
            file.size("data/review.html") / 1024^2))
