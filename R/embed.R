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
