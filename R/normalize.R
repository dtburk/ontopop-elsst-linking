#' Normalise a character vector for matching.
#'
#' Steps: lowercase → strip non-alphanumeric (keep spaces) →
#' collapse runs of whitespace → trim.
normalize_label <- function(x) {
  x |>
    tolower() |>
    gsub(pattern = "[^a-z0-9 ]", replacement = " ") |>
    gsub(pattern = "\\s+",        replacement = " ") |>
    trimws()
}

#' Stem every word in a normalised string using the English Snowball stemmer.
#'
#' Call `normalize_label()` first; this function assumes input is already
#' lowercase with no punctuation.
stem_label <- function(x) {
  vapply(x, function(s) {
    if (is.na(s) || nchar(s) == 0) return(NA_character_)
    words  <- strsplit(s, " ")[[1]]
    stemmed <- SnowballC::wordStem(words, language = "english")
    paste(stemmed, collapse = " ")
  }, character(1), USE.NAMES = FALSE)
}
