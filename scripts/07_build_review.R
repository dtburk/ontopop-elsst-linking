#!/usr/bin/env Rscript
# Phase 5 (iteration 2): build the human-review interface.
#
# Reads the Phase 4 LLM-adjudicated shortlist — which, after change 2, covers
# every labelled OntoPop term — and emits one self-contained HTML file with
# one screen per OntoPop term. New vs iteration 1:
#   - hierarchy context for the term and every candidate (change 1)
#   - the match-type criteria shown to reviewers (change 3, shared source via
#     R/match_rules.R)
#   - per-candidate cross-references to every OTHER OntoPop term the ELSST
#     concept was matched to, with match type (change 4)
# The separate Phase 1 exact/stem sections are gone: those pairs now flow
# through Phase 4 and appear inline, flagged via `provenance`.
#
# Output: data/review.html  (self-contained, opens in any browser)

suppressPackageStartupMessages({ library(dplyr); library(jsonlite) })
source("R/match_rules.R")   # MATCH_TYPE_DEFS, MATCH_TYPE_RULES (shared w/ Phase 4)
source("R/hierarchy.R")     # hierarchy_labels()

`%||%` <- function(a, b) if (is.null(a)) b else a
TYPES <- c("exactMatch", "closeMatch", "broadMatch",
           "narrowMatch", "relatedMatch", "none")

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

# ELSST candidate hierarchy as plain label vectors (display context), keyed by
# ELSST id and looked up in the page — avoids duplicating it across the many
# terms each ELSST concept is a candidate for. Drop empties to save space.
labels_of <- function(cell)
  if (is.null(cell) || !nrow(cell)) character(0) else cell$label[!is.na(cell$label)]
el_asc  <- setNames(elsst$ascendants, elsst$id)
el_narr <- setNames(elsst$narrower_1, elsst$id)
ELSST_CTX <- setNames(lapply(sort(unique(r4$elsst_id)), function(eid)
  list(asc  = as.list(labels_of(el_asc[[eid]])),
       narr = as.list(labels_of(el_narr[[eid]])))),
  sort(unique(r4$elsst_id)))
ELSST_CTX <- ELSST_CTX[vapply(ELSST_CTX,
  function(x) length(x$asc) + length(x$narr) > 0, logical(1))]

# ── Cross-references (change 4) ───────────────────────────────────────────────
# For each ELSST concept, every OntoPop term it was matched to (non-none),
# with the match type. Looked up by ELSST id; the current term is filtered
# out in the page. Generalises iteration 1's exact_partners to all match types.
xr <- r4 |>
  filter(!is.na(match_type), match_type != "none") |>
  distinct(elsst_id, ontopop_code, ontopop_pref_en, match_type)
XREF <- lapply(split(xr, xr$elsst_id), function(d)
  lapply(seq_len(nrow(d)), function(i)
    list(code = d$ontopop_code[i], label = d$ontopop_pref_en[i],
         match_type = d$match_type[i])))

# ── Assemble term entries, easiest-first (strongest match type first) ─────────
r4t <- r4 |>
  mutate(rank  = coalesce(match(match_type, TYPES), 99L),
         score = coalesce(cos_sim, jw_sim))

# Sort ascending by OntoPop id, treating the parts on either side of the hyphen
# as numbers (so 501-2 precedes 501-10). All codes are "<major>-<minor>".
order_codes <- r4t |>
  distinct(ontopop_code) |>
  mutate(major = as.integer(sub("-.*$", "", ontopop_code)),
         minor = as.integer(sub("^.*-",  "", ontopop_code))) |>
  arrange(major, minor) |>
  pull(ontopop_code)

term_of <- function(cd) {
  tr <- r4t |> filter(ontopop_code == cd) |> arrange(rank, desc(score))
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
      elsst_id    = tr$elsst_id[i],
      elsst_label = tr$elsst_pref_en[i],
      elsst_def   = tr$elsst_definition[i],
      match_type  = tr$match_type[i],
      rationale   = tr$rationale[i],
      jw_sim      = tr$jw_sim[i],
      cos_sim     = tr$cos_sim[i],
      provenance  = tr$provenance[i],
      phase1_tier = tr$phase1_tier[i])))
}
terms <- lapply(order_codes, term_of)

n_cands <- sum(vapply(terms, function(t) length(t$candidates), integer(1)))
cat(sprintf("Building %d terms, %d pairs; %d ELSST ctx entries, %d xref entries\n",
            length(terms), n_cands, length(ELSST_CTX), length(XREF)))

# ── Match-type criteria HTML (change 3, from the shared constants) ────────────
esc_html <- function(s) {
  s <- gsub("&", "&amp;", s, fixed = TRUE); s <- gsub("<", "&lt;", s, fixed = TRUE)
  s <- gsub(">", "&gt;", s, fixed = TRUE);  gsub("\"", "&quot;", s, fixed = TRUE)
}
defs_html <- paste0(
  "<dl class=\"rules-defs\">",
  paste(sprintf("<dt class=\"badge b-%s\">%s</dt><dd>%s</dd>",
                names(MATCH_TYPE_DEFS), names(MATCH_TYPE_DEFS),
                esc_html(unname(MATCH_TYPE_DEFS))), collapse = ""),
  "</dl>")
rules_html <- paste0("<pre class=\"rules-text\">", esc_html(MATCH_TYPE_RULES), "</pre>")
match_rules_html <- paste0(defs_html, rules_html)

# ── Emit JSON into the template ───────────────────────────────────────────────
esc_js <- function(s) gsub("</", "<\\/", s, fixed = TRUE)
review_json <- esc_js(toJSON(terms,     auto_unbox = TRUE, na = "null"))
ctx_json    <- esc_js(toJSON(ELSST_CTX, auto_unbox = TRUE, na = "null"))
xref_json   <- esc_js(toJSON(XREF,      auto_unbox = TRUE, na = "null"))

inject <- function(tmpl, key, value) {
  parts <- strsplit(tmpl, key, fixed = TRUE)[[1]]
  if (length(parts) != 2) stop("placeholder ", key, " missing or duplicated")
  paste0(parts[1], value, parts[2])
}
tmpl <- readChar("R/review_template.html",
                 file.info("R/review_template.html")$size)
html <- tmpl |>
  inject("__MATCH_RULES_HTML__", match_rules_html) |>
  inject("__ELSST_CTX__",        ctx_json) |>
  inject("__XREF__",             xref_json) |>
  inject("__REVIEW_DATA__",      review_json)

writeLines(html, "data/review.html", useBytes = TRUE)
cat(sprintf("Wrote data/review.html (%.1f MB)\n",
            file.size("data/review.html") / 1024^2))
