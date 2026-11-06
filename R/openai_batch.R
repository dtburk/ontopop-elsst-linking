#' Helpers for the OpenAI Batch API (upload → create → poll → download).
#'
#' All calls read the key from the `OPENAI_API_KEY` environment variable.

.openai_req <- function(path) {
  key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(key)) stop("OPENAI_API_KEY is not set")
  httr2::request("https://api.openai.com") |>
    httr2::req_url_path_append(path) |>
    httr2::req_auth_bearer_token(key) |>
    httr2::req_retry(
      max_tries = 6, backoff = ~ 2 ^ .x,
      # httr2's default only retries 429/503; OpenAI also throws transient
      # 500/502/504 under load, so retry those too (and connection errors,
      # which httr2 treats as transient regardless).
      is_transient = ~ httr2::resp_status(.x) %in% c(429, 500, 502, 503, 504)) |>
    httr2::req_timeout(120)
}

#' Upload a local file; returns the file id.
openai_upload_file <- function(path, purpose = "batch") {
  resp <- .openai_req("v1/files") |>
    httr2::req_body_multipart(purpose = purpose,
                              file = curl::form_file(path)) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)$id
}

#' Create a batch job over an uploaded JSONL input file.
openai_create_batch <- function(input_file_id,
                                 endpoint = "/v1/chat/completions",
                                 window = "24h") {
  resp <- .openai_req("v1/batches") |>
    httr2::req_body_json(list(input_file_id = input_file_id,
                              endpoint = endpoint,
                              completion_window = window)) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)
}

#' Retrieve the current state of a batch job.
openai_get_batch <- function(batch_id) {
  httr2::resp_body_json(httr2::req_perform(
    .openai_req(paste0("v1/batches/", batch_id))))
}

#' Download a file's content as a string (e.g. a batch output file).
openai_download_file <- function(file_id) {
  httr2::resp_body_string(httr2::req_perform(
    .openai_req(paste0("v1/files/", file_id, "/content"))))
}
