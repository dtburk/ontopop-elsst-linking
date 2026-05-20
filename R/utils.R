#' Pick the first text matching `xpath` under `node`, or NA if none.
xml_first_text <- function(node, xpath, ns = xml2::xml_ns(node)) {
  m <- xml2::xml_find_first(node, xpath, ns)
  if (inherits(m, "xml_missing")) NA_character_ else xml2::xml_text(m)
}

#' All text values matching `xpath`, in document order.
xml_all_text <- function(node, xpath, ns = xml2::xml_ns(node)) {
  xml2::xml_text(xml2::xml_find_all(node, xpath, ns))
}

#' Named attribute value of every node matching `xpath`.
xml_all_attr <- function(node, xpath, attr, ns = xml2::xml_ns(node)) {
  xml2::xml_attr(xml2::xml_find_all(node, xpath, ns), attr)
}

#' Pick the text of the first child matching `xpath` whose xml:lang == `lang`.
#'
#' Avoids `[@xml:lang='...']` predicates so we don't depend on xml2's
#' handling of the xml namespace; pulls all matches and filters in R.
xml_first_text_in_lang <- function(node, xpath, lang = "en",
                                   ns = xml2::xml_ns(node)) {
  matches <- xml2::xml_find_all(node, xpath, ns)
  if (length(matches) == 0) return(NA_character_)
  hit <- which(xml2::xml_attr(matches, "lang") == lang)[1]
  if (is.na(hit)) NA_character_ else xml2::xml_text(matches[[hit]])
}

#' All text values matching `xpath` filtered to xml:lang == `lang`.
xml_all_text_in_lang <- function(node, xpath, lang = "en",
                                 ns = xml2::xml_ns(node)) {
  matches <- xml2::xml_find_all(node, xpath, ns)
  if (length(matches) == 0) return(character())
  matches <- matches[xml2::xml_attr(matches, "lang") == lang]
  xml2::xml_text(matches)
}
