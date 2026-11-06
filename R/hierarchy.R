#' Resolve hierarchy context (ascendants + one generation of descendants)
#' for the OntoPop and ELSST tidy tables.
#'
#' Both vocabularies are directed acyclic graphs, not trees: an OntoPop class
#' can have several `rdfs:subClassOf` parents (max 7 in OntoPop_RDF-XML_
#' 20260327) and an ELSST concept several `skos:broader` parents (max 4 in
#' ELSST R6). The resolvers below therefore do a level-by-level breadth-first
#' walk so ascendants come out nearest-first, deduped across paths, with a
#' visited-set guard against cycles.
#'
#' Each context column is a list-column of one `tibble(id, label)` per row
#' (0+ rows), so it serialises straight to a JSON array of `{id, label}`
#' objects for the Phase 5 review UI and is easy to fold into embedding text
#' in Phase 3. `label` is the target's `pref_en` (may be NA if the target
#' lacks an English label).

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Ascendants of every node, nearest-first.
#'
#' @param ids character vector of node ids (one per row of the table).
#' @param parents_list list parallel to `ids`; element i is the character
#'   vector of immediate-parent ids for node i (NAs / anonymous targets are
#'   dropped here).
#' @return list parallel to `ids` of ancestor-id character vectors, ordered
#'   nearest (direct parents) to farthest (roots), each id appearing once.
resolve_ascendants <- function(ids, parents_list) {
  pmap <- setNames(parents_list, ids)
  lapply(ids, function(start) {
    out      <- character(0)
    visited  <- start                       # never revisit the start node
    frontier <- pmap[[start]]
    frontier <- frontier[!is.na(frontier)]
    while (length(frontier)) {
      frontier <- setdiff(unique(frontier), visited)   # dedupe; keep nearest
      if (!length(frontier)) break
      out      <- c(out, frontier)                      # this level, in order
      visited  <- c(visited, frontier)
      nxt      <- unlist(pmap[frontier], use.names = FALSE)
      frontier <- nxt[!is.na(nxt)]
    }
    out
  })
}

#' Direct children of every node (inverse of `parents_list`), one generation.
#'
#' Used for OntoPop, which has no explicit child property — invert the
#' `rdfs:subClassOf` edges. Returns ids in document order.
resolve_children <- function(ids, parents_list) {
  child  <- rep(ids, lengths(parents_list))
  parent <- unlist(parents_list, use.names = FALSE)
  keep   <- !is.na(parent)
  idx    <- split(child[keep], parent[keep])
  lapply(ids, function(p) idx[[p]] %||% character(0))
}

#' Turn a list of id-vectors into a list of `tibble(id, label)`.
attach_labels <- function(id_list, label_map) {
  lapply(id_list, function(v) {
    tibble::tibble(id = as.character(v), label = unname(label_map[v]))
  })
}

#' Pull labels out of one hierarchy list-column cell (a `tibble(id, label)`,
#' possibly 0-row), nearest-first, dropping NA/blank labels and capping at
#' `max_n`. Returns a character vector (length 0 if none). Shared by the
#' Phase 3 embedding text, the Phase 4 prompt, and the Phase 5 review UI.
hierarchy_labels <- function(cell, max_n = Inf) {
  if (is.null(cell) || !nrow(cell)) return(character(0))
  labs <- cell$label
  labs <- labs[!is.na(labs) & nzchar(trimws(labs))]
  if (length(labs) > max_n) labs <- labs[seq_len(max_n)]
  labs
}

#' Add `ascendants` (all subClassOf ancestors, nearest-first) and `children`
#' (direct subclasses) context columns to the OntoPop table.
add_ontopop_hierarchy <- function(ontopop) {
  label_map <- setNames(ontopop$pref_en, ontopop$id)
  asc <- resolve_ascendants(ontopop$id, ontopop$parents)
  chl <- resolve_children(ontopop$id, ontopop$parents)
  ontopop$ascendants <- attach_labels(asc, label_map)
  ontopop$children   <- attach_labels(chl, label_map)
  ontopop
}

#' Add `ascendants` (all broader concepts, nearest-first) and `narrower_1`
#' (first generation of narrower concepts) context columns to the ELSST table.
#'
#' `narrower_1` uses the asserted `skos:narrower` column directly (ELSST R6
#' asserts broader/narrower as mutual inverses); it is a single generation.
add_elsst_hierarchy <- function(elsst) {
  label_map <- setNames(elsst$pref_en, elsst$id)
  asc <- resolve_ascendants(elsst$id, elsst$broader)
  elsst$ascendants <- attach_labels(asc, label_map)
  elsst$narrower_1 <- attach_labels(elsst$narrower, label_map)
  elsst
}
