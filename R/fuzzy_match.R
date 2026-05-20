#' Token-sorted normalised label: words sorted alphabetically, space-joined.
#'
#' Lets Jaro-Winkler see past word-order differences (e.g.
#' `population group` vs `group of population`). Call `normalize_label()`
#' first; this assumes input is already lowercase with no punctuation.
token_sort <- function(x) {
  vapply(x, function(s) {
    if (is.na(s) || nchar(s) == 0) return(NA_character_)
    paste(sort(strsplit(s, " ")[[1]]), collapse = " ")
  }, character(1), USE.NAMES = FALSE)
}

#' Top-k fuzzy candidate pairs between two label pools.
#'
#' For every OntoPop label, computes Jaro-Winkler similarity against every
#' ELSST label twice — once on the normalised string, once on its
#' token-sorted variant — and keeps the higher of the two. Pairs at or above
#' `threshold` are collapsed to one row per (OntoPop concept, ELSST concept),
#' keeping the best-scoring label pairing, then trimmed to the top `k` ELSST
#' concepts per OntoPop concept.
#'
#' Both pools must carry: ontopop_id/elsst_id, *_code/*_uuid, *_pref_en,
#' `label`, `label_type`, `label_norm`, `label_sort`.
#'
#' @return A tibble of candidate pairs, one row per concept pair.
fuzzy_candidates <- function(op_pool, ep_pool, k = 5, threshold = 0.85,
                             p = 0.1) {
  d_norm <- stringdist::stringdistmatrix(op_pool$label_norm, ep_pool$label_norm,
                                         method = "jw", p = p)
  d_sort <- stringdist::stringdistmatrix(op_pool$label_sort, ep_pool$label_sort,
                                         method = "jw", p = p)
  sim <- pmax(1 - d_norm, 1 - d_sort)

  hits <- which(sim >= threshold, arr.ind = TRUE)
  if (nrow(hits) == 0) return(tibble::tibble())

  tibble::tibble(
    ontopop_id         = op_pool$ontopop_id[hits[, 1]],
    ontopop_code       = op_pool$ontopop_code[hits[, 1]],
    ontopop_pref_en    = op_pool$ontopop_pref_en[hits[, 1]],
    ontopop_label      = op_pool$label[hits[, 1]],
    ontopop_label_type = op_pool$label_type[hits[, 1]],
    elsst_id           = ep_pool$elsst_id[hits[, 2]],
    elsst_uuid         = ep_pool$elsst_uuid[hits[, 2]],
    elsst_pref_en      = ep_pool$elsst_pref_en[hits[, 2]],
    elsst_label        = ep_pool$label[hits[, 2]],
    elsst_label_type   = ep_pool$label_type[hits[, 2]],
    jw_sim             = sim[hits]
  ) |>
    # one row per concept pair: keep the best-scoring label pairing
    dplyr::group_by(ontopop_id, elsst_id) |>
    dplyr::slice_max(jw_sim, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    # top-k ELSST concepts per OntoPop concept
    dplyr::group_by(ontopop_id) |>
    dplyr::slice_max(jw_sim, n = k, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::arrange(ontopop_code, dplyr::desc(jw_sim))
}
