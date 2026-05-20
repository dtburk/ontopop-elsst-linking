#!/usr/bin/env Rscript
# Phase 4: LLM adjudication of candidate pairs via the OpenAI Batch API.
#
# The org's gpt-4o batch enqueued-token limit (90k) is far below this job's
# ~611k input tokens, so the work is split into sub-batches under that cap
# and submitted one at a time — each chunk must finish (and drain from the
# queue) before the next is enqueued.
#
# Idempotent and resumable: each run advances the state machine by one step
# (submit the next chunk, poll the in-flight chunk, or collect a finished
# one). Run repeatedly until it prints PHASE4_DONE.
#
#   Rscript scripts/06_adjudicate.R          (needs OPENAI_API_KEY)
#
# Outputs (on completion):
#   data/candidates_phase4.csv / .rds  — every pair with an LLM match_type
# State / cache:
#   data/cache/batch_phase4.rds  — chunks, batch ids, accumulated verdicts

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(readr)
})

source("R/openai_batch.R")

`%||%` <- function(a, b) if (is.null(a)) b else a

MODEL        <- "gpt-4o"
state_file   <- "data/cache/batch_phase4.rds"
TOKEN_BUDGET <- 78000   # per-chunk input-token cap, safely under the 90k limit

SYS_MSG <- paste(
  "You are an expert in SKOS thesaurus alignment. You compare a source",
  "concept against candidate concepts from a target thesaurus and classify",
  "how each candidate relates to the source. Respond only with JSON.")

# ── Prompt builder ────────────────────────────────────────────────────────────
build_user_msg <- function(term_pref, term_gloss, cand) {
  lines <- vapply(seq_len(nrow(cand)), function(j) {
    d <- cand$elsst_definition[j]
    d <- if (is.na(d) || !nzchar(d)) "(no definition)" else d
    sprintf("%d. %s — %s", j, cand$elsst_pref_en[j], d)
  }, character(1))
  paste0(
    "SOURCE CONCEPT (OntoPop):\n",
    "Label: ", term_pref, "\n",
    "Definition: ", if (is.na(term_gloss)) "(none)" else term_gloss, "\n\n",
    "CANDIDATE CONCEPTS (ELSST):\n", paste(lines, collapse = "\n"), "\n\n",
    "For each candidate, classify its relationship TO THE SOURCE concept as ",
    "exactly one of: exactMatch, closeMatch, broadMatch, narrowMatch, ",
    "relatedMatch, none.\n",
    "- exactMatch: the same concept\n",
    "- closeMatch: nearly the same; interchangeable in most contexts\n",
    "- broadMatch: the candidate is broader (more general) than the source\n",
    "- narrowMatch: the candidate is narrower (more specific) than the source\n",
    "- relatedMatch: associated, but not equivalence or hierarchy\n",
    "- none: no meaningful relationship\n\n",
    "Return JSON {\"results\":[{\"candidate\":1,\"match_type\":\"...\",",
    "\"rationale\":\"one sentence\"}]} with exactly one entry per candidate.")
}

request_line <- function(code, user) {
  toJSON(list(
    custom_id = code,
    method    = "POST",
    url       = "/v1/chat/completions",
    body      = list(
      model           = MODEL,
      messages        = list(list(role = "system", content = SYS_MSG),
                             list(role = "user",   content = user)),
      response_format = list(type = "json_object"),
      max_tokens      = 1500,
      temperature     = 0)
  ), auto_unbox = TRUE)
}

# ── Build chunked state on first run ──────────────────────────────────────────
if (!file.exists(state_file)) {
  candidates <- readRDS("data/candidates_phase3.rds") |>
    group_by(ontopop_code) |>
    mutate(candidate = row_number()) |>
    ungroup()
  index_tbl <- candidates |> select(ontopop_code, candidate, elsst_id)

  reqs <- lapply(candidates |> group_split(ontopop_code), function(ct) {
    user <- build_user_msg(ct$ontopop_pref_en[1], ct$ontopop_gloss[1], ct)
    # conservative token estimate (~3.7 chars/token) of the prompt content
    tok  <- ceiling((nchar(SYS_MSG) + nchar(user)) / 3.7) + 30
    list(code = ct$ontopop_code[1],
         line = as.character(request_line(ct$ontopop_code[1], user)),
         tok  = tok)
  })

  # greedy first-fit chunking by token budget
  chunk_id <- integer(length(reqs)); cur <- 1L; acc <- 0
  for (i in seq_along(reqs)) {
    if (acc > 0 && acc + reqs[[i]]$tok > TOKEN_BUDGET) { cur <- cur + 1L; acc <- 0 }
    chunk_id[i] <- cur; acc <- acc + reqs[[i]]$tok
  }
  chunks <- unname(lapply(split(reqs, chunk_id), function(g) list(
    lines    = vapply(g, `[[`, character(1), "line"),
    tok      = sum(vapply(g, `[[`, numeric(1), "tok")),
    batch_id = NA_character_,
    done     = FALSE)))

  saveRDS(list(index = index_tbl, chunks = chunks, verdicts = tibble()),
          state_file)
  message(sprintf("Built %d chunks from %d terms (~%s input tokens)",
                  length(chunks), length(reqs),
                  format(sum(vapply(chunks, `[[`, numeric(1), "tok")),
                         big.mark = ",")))
}

state   <- readRDS(state_file)
nchunks <- length(state$chunks)
done    <- vapply(state$chunks, `[[`, logical(1), "done")

# ── Per-output-line parser ────────────────────────────────────────────────────
parse_line <- function(ln) {
  o  <- fromJSON(ln, simplifyVector = FALSE)
  sc <- o$response$status_code %||% 0
  if (sc != 200) return(tibble())
  res <- tryCatch(fromJSON(o$response$body$choices[[1]]$message$content)$results,
                  error = function(e) NULL)
  if (is.null(res) || !nrow(res)) return(tibble())
  tibble(ontopop_code = o$custom_id,
         candidate    = as.integer(res$candidate),
         match_type   = as.character(res$match_type),
         rationale    = as.character(res$rationale))
}

# ══ FINAL COLLECT ═════════════════════════════════════════════════════════════
if (all(done)) {
  phase3 <- readRDS("data/candidates_phase3.rds")
  result <- state$index |>
    left_join(state$verdicts, by = c("ontopop_code", "candidate")) |>
    left_join(phase3, by = c("ontopop_code", "elsst_id")) |>
    mutate(match_type = ifelse(is.na(match_type), "unparsed", match_type)) |>
    arrange(ontopop_code, candidate) |>
    select(ontopop_id, ontopop_code, ontopop_pref_en, ontopop_gloss,
           elsst_id, elsst_uuid, elsst_pref_en, elsst_definition,
           jw_sim, cos_sim, provenance, match_type, rationale)

  cat("\n=== Phase 4 results ===\n")
  cat("Adjudicated pairs:", nrow(result),
      " OntoPop terms:", n_distinct(result$ontopop_code), "\n\n")
  result |> count(match_type) |> arrange(desc(n)) |>
    as.data.frame() |> print(row.names = FALSE)
  cat("\nOntoPop terms with >=1 exact/closeMatch:",
      result |> filter(match_type %in% c("exactMatch", "closeMatch")) |>
        pull(ontopop_code) |> n_distinct(), "\n")

  saveRDS(result, "data/candidates_phase4.rds")
  write_csv(result, "data/candidates_phase4.csv")
  cat("\nPHASE4_DONE — saved data/candidates_phase4.csv\n")
  quit(status = 0)
}

# ══ ADVANCE THE CURRENT CHUNK ═════════════════════════════════════════════════
cur <- which(!done)[1]
ch  <- state$chunks[[cur]]

if (is.na(ch$batch_id)) {                                   # ── submit
  path <- sprintf("data/cache/batch_phase4_chunk%02d.jsonl", cur)
  writeLines(ch$lines, path, useBytes = TRUE)
  message(sprintf("Submitting chunk %d/%d (%d requests, ~%s tokens) ...",
                  cur, nchunks, length(ch$lines),
                  format(ch$tok, big.mark = ",")))
  file_id <- openai_upload_file(path)
  batch   <- openai_create_batch(file_id)
  state$chunks[[cur]]$batch_id <- batch$id
  saveRDS(state, state_file)
  cat(sprintf("Chunk %d/%d submitted: %s (status: %s)\n",
              cur, nchunks, batch$id, batch$status))
  quit(status = 0)
}

batch <- openai_get_batch(ch$batch_id)                      # ── poll
rc    <- batch$request_counts
cat(sprintf("Chunk %d/%d %s: %s  [%s/%s done, %s failed]\n",
            cur, nchunks, batch$id, batch$status,
            rc$completed %||% 0, rc$total %||% 0, rc$failed %||% 0))

if (batch$status %in% c("failed", "expired", "cancelled")) {
  if (!is.null(batch$errors))
    cat("  reason:", batch$errors$data[[1]]$message, "\n")
  stop("Chunk batch did not complete (status: ", batch$status, "). ",
       "Clear the batch_id for chunk ", cur, " in ", state_file,
       " to retry.")
}
if (batch$status != "completed") {
  cat("Not finished yet — rerun later.\n")
  quit(status = 0)
}

# ── completed: parse, accumulate, mark done ───────────────────────────────────
out_lines <- strsplit(openai_download_file(batch$output_file_id), "\n")[[1]]
verdicts  <- bind_rows(lapply(out_lines[nzchar(out_lines)], parse_line))
state$verdicts        <- bind_rows(state$verdicts, verdicts)
state$chunks[[cur]]$done <- TRUE
saveRDS(state, state_file)
cat(sprintf("Chunk %d/%d collected: %d verdicts (%d/%d chunks done)\n",
            cur, nchunks, nrow(verdicts), sum(!done) * 0 + cur, nchunks))
