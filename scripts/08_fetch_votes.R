#!/usr/bin/env Rscript
# Phase 5b: download reviewer votes from the shared Firestore database used by
# the review site (docs/; see REVIEW_SITE.md) and join them to the Phase 4
# candidates. Replaces the old interface's "Export CSV" button.
#
# Reads the Firebase project from docs/config.json and uses the public
# Firestore REST API (the security rules allow reads), so no login is needed.
#
# Output:
#   data/review_votes.csv    one row per human vote (long format)
#   data/review_summary.csv  one row per link (gpt-4o candidates and links
#                            added by reviewers): the gpt-4o assignment, if any,
#                            plus human vote counts by type

suppressPackageStartupMessages({ library(dplyr); library(jsonlite) })
`%||%` <- function(a, b) if (is.null(a)) b else a

# ── Firestore REST helpers ────────────────────────────────────────────────────
#' All documents of a collection, following pagination.
fetch_collection <- function(cfg, name) {
  base_url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents",
    cfg$projectId)
  docs <- list(); token <- NULL
  repeat {
    url <- sprintf("%s/%s?pageSize=300&key=%s%s", base_url, name, cfg$apiKey,
                   if (is.null(token)) "" else paste0("&pageToken=", URLencode(token, reserved = TRUE)))
    res <- fromJSON(url, simplifyVector = FALSE)
    docs <- c(docs, res$documents %||% list())
    token <- res$nextPageToken
    if (is.null(token)) break
  }
  docs
}

#' Decode a Firestore typed value ({"stringValue": ...}, {"mapValue": ...}, …).
fs_value <- function(v) {
  if (!is.null(v$mapValue))       return(lapply(v$mapValue$fields %||% list(), fs_value))
  if (!is.null(v$stringValue))    return(v$stringValue)
  if (!is.null(v$timestampValue)) return(v$timestampValue)
  if (!is.null(v$integerValue))   return(as.numeric(v$integerValue))
  if (!is.null(v$doubleValue))    return(v$doubleValue)
  if (!is.null(v$booleanValue))   return(v$booleanValue)
  if (!is.null(v$arrayValue))     return(lapply(v$arrayValue$values %||% list(), fs_value))
  NULL                                             # nullValue and anything else
}
doc_id     <- function(d) sub(".*/", "", d$name)
doc_fields <- function(d) lapply(d$fields %||% list(), fs_value)
parse_ts   <- function(x) as.POSIXct(sub("\\.\\d+Z$|Z$", "", x), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")

#' Flatten vote_shards documents into one row per vote.
votes_table <- function(shard_docs) {
  rows <- list()
  for (d in shard_docs) {
    v <- doc_fields(d)$v %||% list()
    for (pk in names(v)) for (rid in names(v[[pk]])) {
      x <- v[[pk]][[rid]]
      if (is.null(x$t)) next
      rows[[length(rows) + 1]] <- tibble(
        pair_key = pk, reviewer_id = rid, match_type = x$t, note = x$n %||% "",
        created = x$c %||% NA_character_, updated = x$u %||% NA_character_)
    }
  }
  if (!length(rows)) return(tibble(pair_key = character(), reviewer_id = character(),
    match_type = character(), note = character(), created = character(), updated = character()))
  bind_rows(rows) |>
    mutate(ontopop_code = sub("\\|.*$", "", pair_key),
           elsst_uuid   = sub("^.*\\|", "", pair_key),
           created = parse_ts(created), updated = parse_ts(updated))
}

#' Reviewer-added links (pairs gpt-4o never proposed) from the shards' x maps.
added_table <- function(shard_docs) {
  rows <- list()
  for (d in shard_docs) {
    x <- doc_fields(d)$x %||% list()
    for (pk in names(x)) {
      a <- x[[pk]]
      if (is.null(a$e)) next
      rows[[length(rows) + 1]] <- tibble(pair_key = pk, elsst_id = a$e,
        added_by = a$by %||% NA_character_, added_at = a$c %||% NA_character_)
    }
  }
  if (!length(rows)) return(tibble(pair_key = character(), elsst_id = character(),
    added_by = character(), added_at = as.POSIXct(character())))
  bind_rows(rows) |> mutate(added_at = parse_ts(added_at))
}

reviewers_table <- function(docs) {
  bind_rows(lapply(docs, function(d) {
    f <- doc_fields(d)
    tibble(reviewer_id = doc_id(d), reviewer_name = f$name %||% NA_character_,
           reviewer_affiliation = f$affiliation %||% NA_character_)
  }))
}

# ── Fetch, join, write ────────────────────────────────────────────────────────
if (sys.nframe() == 0L) {          # run as a script (not when source()d)
  cfg <- fromJSON("docs/config.json")$firebase
  if (!nzchar(cfg$projectId %||% "") || !nzchar(cfg$apiKey %||% ""))
    stop("docs/config.json has no Firebase projectId/apiKey — see REVIEW_SITE.md")
  reviewers <- reviewers_table(fetch_collection(cfg, "reviewers"))
  shards    <- fetch_collection(cfg, "vote_shards")
  votes     <- votes_table(shards)
  added     <- added_table(shards)

  # Every link: the gpt-4o candidates plus reviewer-added pairs.
  r4 <- readRDS("data/candidates_phase4.rds") |>
    transmute(pair_key = paste0(ontopop_code, "|", elsst_uuid), link_source = "gpt-4o",
              ontopop_code, ontopop_id, ontopop_pref_en, elsst_id, elsst_pref_en,
              llm_match_type = match_type, llm_rationale = rationale)
  ontopop <- readRDS("data/cache/ontopop.rds")
  elsst   <- readRDS("data/cache/elsst.rds")
  added_links <- added |>
    filter(!pair_key %in% r4$pair_key) |>
    left_join(reviewers |> select(reviewer_id, added_by_name = reviewer_name),
              by = c("added_by" = "reviewer_id")) |>
    mutate(ontopop_code = sub("\\|.*$", "", pair_key), link_source = "reviewer-added") |>
    left_join(ontopop |> select(ontopop_code = code, ontopop_id = id, ontopop_pref_en = pref_en),
              by = "ontopop_code") |>
    left_join(elsst |> select(elsst_id = id, elsst_pref_en = pref_en), by = "elsst_id")
  links <- bind_rows(r4, added_links |> select(-added_by))

  long <- votes |>
    left_join(reviewers, by = "reviewer_id") |>
    left_join(links |> select(-ontopop_code), by = "pair_key") |>
    select(ontopop_code, ontopop_pref_en, elsst_pref_en, link_source, llm_match_type,
           reviewer_name, reviewer_affiliation, match_type, note, created, updated,
           ontopop_id, elsst_id, reviewer_id) |>
    arrange(ontopop_code, elsst_pref_en, created)
  orphans <- sum(is.na(long$link_source))
  if (orphans) warning(orphans, " vote(s) refer to links that are neither in ",
                       "candidates_phase4.rds nor reviewer-added")

  summary <- links |>
    left_join(votes |> count(pair_key, match_type) |>
                tidyr::pivot_wider(names_from = match_type, values_from = n,
                                   names_prefix = "votes_", values_fill = 0),
              by = "pair_key") |>
    mutate(across(starts_with("votes_"), \(x) coalesce(x, 0L)))
  summary$n_reviewers <- rowSums(select(summary, starts_with("votes_")))

  write.csv(long,    "data/review_votes.csv",   row.names = FALSE, na = "")
  write.csv(summary, "data/review_summary.csv", row.names = FALSE, na = "")
  cat(sprintf("%d reviewers, %d votes on %d links (%d gpt-4o candidates + %d reviewer-added). Wrote data/review_votes.csv and data/review_summary.csv
",
              nrow(reviewers), nrow(votes), n_distinct(votes$pair_key), nrow(r4), nrow(added_links)))
}
