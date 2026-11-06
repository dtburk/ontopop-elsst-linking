#!/usr/bin/env Rscript
# Build the data for the OntoPop browser (docs/browse.html).
#
# A read-only companion to the review site: browse OntoPop by its class
# hierarchy and, for any class, see all of its OWL metadata plus every ELSST
# concept gpt-4o matched to it in Phase 4 (match type != "none"), each with a
# link to the CESSDA Data Catalogue datasets that carry that ELSST keyword.
#
#   Rscript scripts/09_build_browse.R            (reuses cached CESSDA counts)
#   Rscript scripts/09_build_browse.R --refresh  (re-fetches CESSDA counts)
#
# Inputs:  OntoPop_RDF-XML_20260327.owl, data/cache/ontopop.rds (glosses),
#          data/cache/elsst.rds, data/candidates_phase4.rds
# Outputs: docs/browse.json              classes, matches, ELSST concepts,
#                                        English context text
#          docs/browse_ctx/<lang>.json   context text for each other language
#                                        (loaded by the page on demand)
# Cache:   data/cache/cessda_counts.rds  dataset count per ELSST label
#
# CESSDA dataset counts. The catalogue link is the one ELSST itself shows
# ("Search for 'X' in CESSDA Data Catalogue"): an exact filter on the
# keyword facet of the English index. The public API
# (/api/DataSets/v2/search?keywords=) is a full-text match instead, so it
# over-counts badly (FAMILY: 2,773 vs 66), and the catalogue's own exact
# facet endpoint (/api/sk/_search) sends no CORS header, so a GitHub Pages
# site cannot call it from the browser. We therefore query that endpoint
# here, at build time, and ship the counts as a dated snapshot.

suppressPackageStartupMessages({
  library(dplyr); library(jsonlite); library(xml2); library(httr2)
})

`%||%` <- function(a, b) if (is.null(a)) b else a
OWL      <- "OntoPop_RDF-XML_20260327.owl"
OUT      <- "docs/browse.json"
CTX_DIR  <- "docs/browse_ctx"
CNT_FILE <- "data/cache/cessda_counts.rds"
REFRESH  <- "--refresh" %in% commandArgs(trailingOnly = TRUE)
TYPES    <- c("exactMatch", "closeMatch", "broadMatch", "narrowMatch", "relatedMatch")

NS <- c(rdf     = "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
        rdfs    = "http://www.w3.org/2000/01/rdf-schema#",
        owl     = "http://www.w3.org/2002/07/owl#",
        skos    = "http://www.w3.org/2004/02/skos/core#",
        ontoPop = "http://www.semanticweb.org/altergc/ontologies/2025/5/ontoPop#")
ONTO_NS <- NS[["ontoPop"]]
code_of <- function(iri) ifelse(startsWith(iri, ONTO_NS),
                                substring(iri, nchar(ONTO_NS) + 1), iri)

# ── 1. Parse every property of every named class, generically ────────────────
# One row per child element of each owl:Class[@rdf:about], so nothing in the
# file is left out: labels, alt labels, context/definition text in every
# language, subClassOf, deprecated flags, and anything else present.
message("Parsing ", OWL, " ...")
doc     <- read_xml(OWL)
ont_iri <- xml_attr(xml_find_first(doc, "//owl:Ontology", NS), "about")
ont_ver <- xml_attr(xml_find_first(doc, "//owl:Ontology/owl:versionIRI", NS), "resource")
kids    <- xml_find_all(doc, "//owl:Class[@rdf:about]/*", NS)
props <- tibble(
  iri  = xml_attr(xml_find_first(kids, ".."), "about"),
  prop = xml_name(kids, NS),
  lang = xml_attr(kids, "lang"),
  res  = xml_attr(kids, "rdf:resource", NS),
  text = trimws(xml_text(kids)))

# Anonymous owl:Restriction superclasses (e.g. measureOf some X).
restr_nodes <- xml_find_all(doc, "//owl:Class[@rdf:about]/rdfs:subClassOf/owl:Restriction", NS)
restr <- tibble(
  iri      = xml_attr(xml_find_first(restr_nodes, "../.."), "about"),
  property = code_of(xml_attr(xml_find_first(restr_nodes, "./owl:onProperty"), "rdf:resource", NS)),
  some     = xml_attr(xml_find_first(restr_nodes, "./owl:someValuesFrom", NS), "rdf:resource", NS),
  all      = xml_attr(xml_find_first(restr_nodes, "./owl:allValuesFrom",  NS), "rdf:resource", NS)) |>
  mutate(kind = ifelse(!is.na(some), "some", "only"),
         target = code_of(coalesce(some, all)))

# subClassOf with an rdf:resource = named parent; without = a restriction
# (handled above), so drop those rows from the generic table.
props <- props |> filter(!(prop == "rdfs:subClassOf" & is.na(res)))

classes <- unique(props$iri)
message(sprintf("  %d classes, %d property values, %d restrictions",
                length(classes), nrow(props), nrow(restr)))

# ── 2. Long context text: store once per (section, language) ─────────────────
# ontoPop:definedInContext is the whole IUSSP dictionary paragraph for the
# class's section, repeated on every class in it, and rdfs:isDefinedBy
# repeats it again. Intern each distinct text and refer to it by key.
long_props <- c("ontoPop:definedInContext", "rdfs:isDefinedBy")
long <- props |> filter(prop %in% long_props, nzchar(text))
texts <- long |> distinct(lang, text) |>
  group_by(lang) |> mutate(key = paste0(ifelse(is.na(lang), "x", lang), ":", row_number())) |> ungroup()
long  <- long |> left_join(texts, by = c("lang", "text"))
props <- props |> filter(!prop %in% long_props)

# ── 3. Hierarchy ─────────────────────────────────────────────────────────────
parents  <- props |> filter(prop == "rdfs:subClassOf") |>
  transmute(child = iri, parent = res)
children <- split(code_of(parents$child), code_of(parents$parent))

# ── 4. Glosses from the pipeline cache ───────────────────────────────────────
op <- readRDS("data/cache/ontopop.rds")
gl <- setNames(lapply(seq_len(nrow(op)), function(i)
  list(gloss_en = op$gloss_en[i], gloss_llm = op$gloss_llm[i])), op$id)

# ── 5. gpt-4o matches (Phase 4, excluding "none") ────────────────────────────
r4 <- readRDS("data/candidates_phase4.rds") |>
  filter(match_type %in% TYPES) |>
  mutate(rank = match(match_type, TYPES)) |>
  arrange(ontopop_code, rank, desc(coalesce(cos_sim, jw_sim)))
message(sprintf("  %d gpt-4o matches (non-none) across %d classes, %d ELSST concepts",
                nrow(r4), n_distinct(r4$ontopop_code), n_distinct(r4$elsst_id)))

el <- readRDS("data/cache/elsst.rds")
el <- el[el$id %in% r4$elsst_id, ]
labels_of <- function(cell) if (is.null(cell) || !nrow(cell)) list() else as.list(cell$label[!is.na(cell$label)])
ELSST <- setNames(lapply(seq_len(nrow(el)), function(i) list(
  label = el$pref_en[i],
  alt   = as.list(el$alt_en[[i]] %||% character(0)),
  def   = el$definition_en[i],
  asc   = labels_of(el$ascendants[[i]]),
  narr  = labels_of(el$narrower_1[[i]]))), el$uuid)

# ── 6. CESSDA Data Catalogue counts (exact keyword facet, English index) ─────
cessda_count_batch <- function(labels) {
  body <- lapply(labels, function(l) list(
    indexName = "cmmstudy_en",
    params    = list(facetFilters = list(list(paste0("keywords:", l))),
                     hitsPerPage = 0, query = "")))
  resp <- request("https://datacatalogue.cessda.eu/api/sk/_search") |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_user_agent("ontopop-elsst-linking browse builder") |>
    req_retry(max_tries = 4) |>
    req_timeout(60) |>
    req_perform()
  vapply(resp_body_json(resp)$results, function(r) as.integer(r$nbHits %||% NA), integer(1))
}
cnt <- if (file.exists(CNT_FILE) && !REFRESH) readRDS(CNT_FILE) else
  list(fetched = NA_character_, counts = setNames(integer(0), character(0)))
need <- setdiff(unique(el$pref_en), names(cnt$counts))
if (length(need)) {
  message(sprintf("Fetching CESSDA counts for %d ELSST labels ...", length(need)))
  for (b in split(need, ceiling(seq_along(need) / 40))) {
    cnt$counts[b] <- tryCatch(cessda_count_batch(b), error = function(e) {
      message("  batch failed: ", conditionMessage(e)); rep(NA_integer_, length(b)) })
    Sys.sleep(0.3)
  }
  cnt$counts  <- cnt$counts[!is.na(cnt$counts)]   # retry failures next run
  cnt$fetched <- format(Sys.Date())
  saveRDS(cnt, CNT_FILE)
}
for (u in names(ELSST)) ELSST[[u]]$n <- unname(cnt$counts[ELSST[[u]]$label] %||% NA)
ELSST <- lapply(ELSST, function(x) { if (length(x$n) == 0 || is.na(x$n)) x$n <- NULL; x })

# ── 7. Assemble per-class records ────────────────────────────────────────────
by_iri   <- split(props, props$iri)
long_by  <- split(long,  long$iri)
restr_by <- split(restr, restr$iri)
r4_by    <- split(r4,    r4$ontopop_code)
grp <- function(d) {   # lang -> values (untagged literals under "")
  if (is.null(d) || !nrow(d)) return(NULL)
  s <- split(d$text, ifelse(is.na(d$lang), "", d$lang))
  lapply(s, as.list)
}

CLASSES <- lapply(classes, function(iri) {
  p  <- by_iri[[iri]]; cd <- code_of(iri)
  lg <- long_by[[iri]]
  other <- p |> filter(!prop %in% c("skos:prefLabel", "skos:altLabel", "rdfs:label",
                                     "rdfs:subClassOf", "owl:deprecated"))
  m <- r4_by[[cd]]
  rs <- restr_by[[iri]]
  out <- list(
    code    = cd,
    label   = op$pref_en[match(iri, op$id)] %||% cd,
    rdfs    = as.list(p$text[p$prop == "rdfs:label"]),
    pref    = grp(p[p$prop == "skos:prefLabel", ]),
    alt     = grp(p[p$prop == "skos:altLabel", ]),
    parents = as.list(code_of(p$res[p$prop == "rdfs:subClassOf"])),
    children = as.list(children[[cd]] %||% character(0)),
    restr   = if (is.null(rs)) list() else lapply(seq_len(nrow(rs)), function(i)
                list(p = rs$property[i], k = rs$kind[i], t = rs$target[i])),
    ctx     = if (is.null(lg)) NULL else
                as.list(setNames(lg$key[lg$prop == "ontoPop:definedInContext"],
                                 lg$lang[lg$prop == "ontoPop:definedInContext"])),
    # rdfs:isDefinedBy: only listed when it differs from definedInContext
    idb     = if (is.null(lg)) NULL else {
                a <- lg[lg$prop == "rdfs:isDefinedBy", ]
                c0 <- lg[lg$prop == "ontoPop:definedInContext", ]
                a <- a[!(a$key %in% c0$key[match(a$lang, c0$lang)]), ]
                if (nrow(a)) as.list(setNames(a$key, a$lang)) else NULL },
    other   = if (!nrow(other)) NULL else lapply(seq_len(nrow(other)), function(i)
                list(p = other$prop[i], l = other$lang[i],
                     v = if (!is.na(other$res[i])) other$res[i] else other$text[i])),
    gloss_en  = gl[[iri]]$gloss_en,
    gloss_llm = gl[[iri]]$gloss_llm,
    matches = if (is.null(m)) list() else lapply(seq_len(nrow(m)), function(i) list(
      u   = m$elsst_uuid[i],
      t   = m$match_type[i],
      why = m$rationale[i],
      jw  = m$jw_sim[i],
      cos = m$cos_sim[i],
      src = m$provenance[i])))
  if (any(p$prop == "owl:deprecated" & tolower(p$text) == "true")) out$deprecated <- TRUE
  out[!vapply(out, is.null, logical(1))]
})
names(CLASSES) <- vapply(CLASSES, `[[`, "", "code")
roots <- setdiff(names(CLASSES), code_of(parents$child))

# ── 8. Write ──────────────────────────────────────────────────────────────────
write_json_file <- function(x, path) {
  con <- file(path, open = "wb")
  writeLines(toJSON(x, auto_unbox = TRUE, na = "null", digits = 4, null = "null"),
             con, useBytes = TRUE)
  close(con)
}
langs <- sort(unique(na.omit(texts$lang)))
lang_text <- function(lg) { t <- texts[texts$lang %in% lg, ]; as.list(setNames(t$text, t$key)) }

dir.create(CTX_DIR, showWarnings = FALSE, recursive = TRUE)
for (lg in setdiff(langs, "en")) write_json_file(lang_text(lg), file.path(CTX_DIR, paste0(lg, ".json")))
write_json_file(list(
  meta = list(built = format(Sys.time(), "%Y-%m-%d"),
              ontology = ont_iri, version = ont_ver, source = OWL,
              n_classes = length(CLASSES), n_matches = nrow(r4),
              cessda_fetched = cnt$fetched,
              langs = as.list(langs), types = as.list(TYPES)),
  roots   = as.list(roots),
  classes = CLASSES,
  elsst   = ELSST,
  ctx_en  = lang_text("en")), OUT)
if (!file.exists("docs/.nojekyll")) invisible(file.create("docs/.nojekyll"))
message(sprintf("Wrote %s (%.1f MB) + %d language files in %s/",
                OUT, file.size(OUT) / 1024^2, length(langs) - 1, CTX_DIR))
