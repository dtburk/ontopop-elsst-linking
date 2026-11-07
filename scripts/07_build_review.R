#!/usr/bin/env Rscript
# Phase 5 (iteration 2): build the data file for the collaborative review site.
#
# The review interface is a static web app in docs/ (served by GitHub Pages;
# see REVIEW_SITE.md). Reviewer votes live in a shared Firestore database, so
# this script only produces the read-only data the app displays:
#
#   docs/review.json  — one entry per OntoPop term (with its candidates and
#                       gpt-4o assignment/rationale), every ELSST concept
#                       (label, definition, alt labels, hierarchy context — so
#                       reviewers can also add links gpt-4o didn't propose),
#                       cross-references, and the match-type criteria HTML.
#
# Contents carried over from iteration 2:
#   - hierarchy context for the term and every candidate (change 1); the
#     OntoPop `chl` lists also drive the app's collapsible hierarchy sidebar
#   - the match-type criteria shown to reviewers (change 3, shared source via
#     R/match_rules.R)
#   - per-candidate cross-references to every OTHER OntoPop term the ELSST
#     concept was matched to, with match type (change 4)
#
# Votes are keyed by OntoPop code + ELSST UUID, so rebuilding this file (e.g.
# after re-running Phase 4) keeps existing votes attached to their links.
# Retrieve the votes with scripts/08_fetch_votes.R.

suppressPackageStartupMessages({ library(dplyr); library(jsonlite) })
source("R/match_rules.R")   # MATCH_TYPE_DEFS, MATCH_TYPE_RULES (shared w/ Phase 4)

`%||%` <- function(a, b) if (is.null(a)) b else a
TYPES <- c("exactMatch", "closeMatch", "broadMatch",
           "narrowMatch", "relatedMatch", "none")
OUT <- "docs/review.json"

# ── Load ──────────────────────────────────────────────────────────────────────
r4      <- readRDS("data/candidates_phase4.rds")
ontopop <- readRDS("data/cache/ontopop.rds")
elsst   <- readRDS("data/cache/elsst.rds")

clean_ctx <- function(s) gsub("\\*+", "", ifelse(is.na(s), "", s))
op_code   <- setNames(ontopop$code,          ontopop$id)
ctx_map   <- setNames(ontopop$definition_en, ontopop$id)

# ── Hierarchy context (change 1) ──────────────────────────────────────────────
# OntoPop term hierarchy as {code,label} so each item can link to its own
# review screen. Full chains (display-full; the N=4 cap is embedding-only).
hier_codes <- function(cell) {
  if (is.null(cell) || !nrow(cell)) return(list())
  lapply(seq_len(nrow(cell)), function(i)
    list(code = unname(op_code[cell$id[i]]), label = cell$label[i]))
}
onto_asc <- setNames(lapply(ontopop$ascendants, hier_codes), ontopop$id)
onto_chl <- setNames(lapply(ontopop$children,   hier_codes), ontopop$id)

# ELSST concepts. Every concept (not just Phase 4 candidates) is shipped so
# reviewers can add links gpt-4o never proposed. Label/definition/alt labels
# live here once, keyed by ELSST id, instead of being repeated on each of the
# ~19k candidate rows; the app looks them up by id.
ELSST <- setNames(lapply(seq_len(nrow(elsst)), function(i) {
  alt <- elsst$alt_en[[i]]
  alt <- if (is.null(alt)) character(0) else alt[!is.na(alt) & nzchar(alt)]
  x <- list(l = elsst$pref_en[i])
  if (!is.na(elsst$definition_en[i])) x$d <- elsst$definition_en[i]
  if (length(alt)) x$a <- as.list(alt)
  x
}), elsst$id)

# ELSST hierarchy as plain label vectors (display context), keyed by ELSST id.
# Drop empties to save space.
labels_of <- function(cell)
  if (is.null(cell) || !nrow(cell)) character(0) else cell$label[!is.na(cell$label)]
ELSST_CTX <- setNames(lapply(seq_len(nrow(elsst)), function(i)
  list(asc  = as.list(labels_of(elsst$ascendants[[i]])),
       narr = as.list(labels_of(elsst$narrower_1[[i]])))),
  elsst$id)
ELSST_CTX <- ELSST_CTX[vapply(ELSST_CTX,
  function(x) length(x$asc) + length(x$narr) > 0, logical(1))]
stopifnot(all(r4$elsst_id %in% names(ELSST)))

# ── Cross-references (change 4) ───────────────────────────────────────────────
# For each ELSST concept, every OntoPop term gpt-4o matched it to (non-none),
# with the match type. Looked up by ELSST id; the current term is filtered
# out in the page.
xr <- r4 |>
  filter(!is.na(match_type), match_type != "none") |>
  distinct(elsst_id, ontopop_code, ontopop_pref_en, match_type)
XREF <- lapply(split(xr, xr$elsst_id), function(d)
  lapply(seq_len(nrow(d)), function(i)
    list(code = d$ontopop_code[i], label = d$ontopop_pref_en[i],
         match_type = d$match_type[i])))

# ── Assemble term entries ─────────────────────────────────────────────────────
# Candidates within a term: strongest gpt-4o match type first, then score.
r4t <- r4 |>
  mutate(rank  = coalesce(match(match_type, TYPES), 99L),
         score = coalesce(cos_sim, jw_sim))

# Terms sorted by OntoPop code, treating the parts on either side of the
# hyphen as numbers (so 501-2 precedes 501-10). All codes are "<major>-<minor>".
# The app uses this order for siblings in the hierarchy sidebar.
order_codes <- r4t |>
  distinct(ontopop_code) |>
  mutate(major = as.integer(sub("-.*$", "", ontopop_code)),
         minor = as.integer(sub("^.*-",  "", ontopop_code))) |>
  arrange(major, minor) |>
  pull(ontopop_code)

by_code <- split(r4t, r4t$ontopop_code)
term_of <- function(cd) {
  tr <- by_code[[cd]] |> arrange(rank, desc(score))
  id <- tr$ontopop_id[1]
  list(
    code    = cd,
    id      = id,
    label   = tr$ontopop_pref_en[1],
    gloss   = tr$ontopop_gloss[1],
    context = clean_ctx(ctx_map[id]),
    asc     = onto_asc[[id]] %||% list(),
    chl     = onto_chl[[id]] %||% list(),
    candidates = lapply(seq_len(nrow(tr)), function(i) list(
      elsst_id    = tr$elsst_id[i],          # label/definition: see ELSST
      match_type  = tr$match_type[i],
      rationale   = tr$rationale[i],
      jw_sim      = tr$jw_sim[i],
      cos_sim     = tr$cos_sim[i],
      provenance  = tr$provenance[i],
      phase1_tier = tr$phase1_tier[i])))
}
terms <- lapply(order_codes, term_of)

n_cands    <- nrow(r4)
n_proposed <- sum(!is.na(r4$match_type) & r4$match_type != "none")
cat(sprintf("Building %d terms, %d links (%d gpt-4o proposals); %d ELSST concepts, %d ctx entries, %d xref entries\n",
            length(terms), n_cands, n_proposed, length(ELSST), length(ELSST_CTX), length(XREF)))

# ── Match-type criteria HTML (change 3, from the shared constants) ────────────
esc_html <- function(s) {
  s <- gsub("&", "&amp;", s, fixed = TRUE); s <- gsub("<", "&lt;", s, fixed = TRUE)
  s <- gsub(">", "&gt;", s, fixed = TRUE);  gsub("\"", "&quot;", s, fixed = TRUE)
}
dt_label <- ifelse(names(MATCH_TYPE_DEFS) == "none", "none (reject)",
                   names(MATCH_TYPE_DEFS))
defs_html <- paste0(
  "<dl class=\"rules-defs\">",
  paste(sprintf("<dt class=\"badge b-%s\">%s</dt><dd>%s</dd>",
                names(MATCH_TYPE_DEFS), dt_label,
                esc_html(unname(MATCH_TYPE_DEFS))), collapse = ""),
  "</dl>")
rules_html <- paste0("<pre class=\"rules-text\">", esc_html(MATCH_TYPE_RULES), "</pre>")

# ── Write ─────────────────────────────────────────────────────────────────────
payload <- list(
  meta = list(built      = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
              n_terms    = length(terms),
              n_links    = n_cands,
              n_proposed = n_proposed,
              type_defs  = as.list(MATCH_TYPE_DEFS)),
  rules_html = paste0(defs_html, rules_html),
  terms      = terms,
  elsst      = ELSST,
  elsst_ctx  = ELSST_CTX,
  xref       = XREF)

dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)
con <- file(OUT, open = "wb")
writeLines(toJSON(payload, auto_unbox = TRUE, na = "null", digits = 4),
           con, useBytes = TRUE)
close(con)
# GitHub Pages: serve files as-is (no Jekyll processing).
if (!file.exists("docs/.nojekyll")) invisible(file.create("docs/.nojekyll"))
cat(sprintf("Wrote %s (%.1f MB)\n", OUT, file.size(OUT) / 1024^2))
