#' Minimal OpenAI chat-completions call; returns the assistant message text.
#'
#' Reads the key from the `OPENAI_API_KEY` environment variable. Retries on
#' transient failures. With `json = TRUE` the model is constrained to emit a
#' JSON object.
openai_chat <- function(messages, model = "gpt-4o-mini", json = TRUE,
                        temperature = 0) {
  key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(key)) stop("OPENAI_API_KEY is not set")

  body <- list(model = model, messages = messages, temperature = temperature)
  if (json) body$response_format <- list(type = "json_object")

  resp <- httr2::request("https://api.openai.com/v1/chat/completions") |>
    httr2::req_auth_bearer_token(key) |>
    httr2::req_body_json(body) |>
    httr2::req_retry(max_tries = 4, backoff = ~ 2 ^ .x) |>
    httr2::req_timeout(120) |>
    httr2::req_perform()

  httr2::resp_body_json(resp)$choices[[1]]$message$content
}

#' Build the user prompt asking for one standalone definition per code.
#'
#' `paragraph` is a section's shared definedInContext prose; `codes` and
#' `labels` are the parallel vectors of IUSSP codes and English prefLabels
#' for the terms defined inside it. Each term appears inline in the prose
#' followed by its code in parentheses, which anchors it for the model.
gloss_prompt <- function(paragraph, codes, labels) {
  terms <- paste0("- ", codes, ": ", labels, collapse = "\n")
  paste0(
    "Below is a paragraph from a demographic dictionary. Each defined term ",
    "appears inline followed by its code in parentheses, ",
    "e.g. \"population (101-4)\".\n\n",
    "PARAGRAPH:\n", paragraph, "\n\n",
    "TERMS TO DEFINE:\n", terms, "\n\n",
    "For each term, write one concise, standalone definition (a single ",
    "sentence) of that specific term, grounded in how the paragraph uses ",
    "it. Do not mention the code or any cross-reference numbers in the ",
    "definition. Define every term listed. Return JSON of the form:\n",
    "{\"definitions\":[{\"code\":\"101-4\",\"definition\":\"...\"}]}"
  )
}
