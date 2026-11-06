# ── Embedding-text composition (iteration 2, change 1) ────────────────────────
# The embedding text for each concept is its label + definition/gloss plus
# structured hierarchy context: a capped list of nearest ascendants and a
# capped list of one generation of descendants. The caps keep the long,
# cross-facet OntoPop chains (depth up to 21) and high-degree descendant sets
# (up to ~40) from drowning the term's own signal; see PLAN2.md Phase 3.
# `hierarchy_labels()` (used below) lives in R/hierarchy.R — source it first.

#' Compose one concept's embedding text from its label, body (definition or
#' gloss), and pre-extracted broader/narrower label vectors. Sections are
#' newline-separated and omitted when empty, so a concept with no definition
#' and no hierarchy reads exactly as `label` alone.
embed_text <- function(label, body = "", broader = character(0),
                       narrower = character(0)) {
  parts <- c(label, body)
  parts <- parts[!is.na(parts) & nzchar(trimws(parts))]
  if (length(broader))
    parts <- c(parts, paste("Broader:",  paste(broader,  collapse = "; ")))
  if (length(narrower))
    parts <- c(parts, paste("Narrower:", paste(narrower, collapse = "; ")))
  trimws(paste(parts, collapse = "\n"))
}

#' Build the embedding-text vector for a whole table. `body` is the column of
#' definition/gloss text; `broader_col` / `narrower_col` are hierarchy
#' list-columns. `n_asc` caps ascendants (nearest-first), `n_desc` caps the
#' descendant generation.
build_embed_text <- function(label, body, broader_col, narrower_col,
                             n_asc = 4, n_desc = 12) {
  vapply(seq_along(label), function(i) {
    embed_text(
      label[i], if (length(body)) body[i] else "",
      broader  = hierarchy_labels(broader_col[[i]],  n_asc),
      narrower = hierarchy_labels(narrower_col[[i]], n_desc))
  }, character(1))
}

#' Embed one batch of texts via the OpenAI embeddings endpoint.
#'
#' Returns a matrix with one row per input, in input order.
openai_embed_batch <- function(texts, model = "text-embedding-3-small") {
  key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(key)) stop("OPENAI_API_KEY is not set")

  resp <- httr2::request("https://api.openai.com/v1/embeddings") |>
    httr2::req_auth_bearer_token(key) |>
    httr2::req_body_json(list(model = model, input = as.list(texts))) |>
    httr2::req_retry(max_tries = 4, backoff = ~ 2 ^ .x) |>
    httr2::req_timeout(120) |>
    httr2::req_perform()

  d   <- httr2::resp_body_json(resp)$data
  idx <- vapply(d, function(x) x$index, integer(1))
  emb <- lapply(d, function(x) as.numeric(unlist(x$embedding)))
  do.call(rbind, emb[order(idx)])
}

#' Embed `texts` in batches; returns a matrix aligned to input order.
openai_embed <- function(texts, model = "text-embedding-3-small",
                         batch_size = 500) {
  n <- length(texts)
  out <- vector("list", ceiling(n / batch_size))
  for (b in seq_along(out)) {
    lo <- (b - 1) * batch_size + 1
    hi <- min(b * batch_size, n)
    out[[b]] <- openai_embed_batch(texts[lo:hi], model)
    message(sprintf("  embedded %d / %d", hi, n))
  }
  do.call(rbind, out)
}

#' Embed `texts` (keyed by `ids`), reusing a disk cache.
#'
#' Only ids that are new or whose text has changed are sent to the API;
#' everything else is served from `cache_path`. Returns a matrix with one
#' row per id, in the order given.
cached_embeddings <- function(ids, texts, cache_path,
                              model = "text-embedding-3-small") {
  cache <- if (file.exists(cache_path)) readRDS(cache_path) else list()

  stale <- vapply(seq_along(ids), function(i) {
    hit <- cache[[ids[i]]]
    is.null(hit) || !identical(hit$text, texts[i])
  }, logical(1))

  if (any(stale)) {
    message(sprintf("Embedding %d / %d texts (%d served from cache) ...",
                    sum(stale), length(ids), sum(!stale)))
    emb <- openai_embed(texts[stale], model)
    si  <- which(stale)
    for (j in seq_along(si)) {
      cache[[ids[si[j]]]] <- list(text = texts[si[j]], emb = emb[j, ])
    }
    saveRDS(cache, cache_path)
  } else {
    message(sprintf("All %d embeddings served from cache.", length(ids)))
  }

  do.call(rbind, lapply(ids, function(id) cache[[id]]$emb))
}
