#' Parse an ELSST RDF/XML file into a tidy tibble.
#'
#' One row per skos:Concept. English labels and definition are scalar
#' columns; altLabels and hierarchy links are list-columns so a concept
#' can hold zero, one, or many values without reshaping.
#'
#' Uses a fixed namespace map for XPath rather than `xml_ns_strip()`,
#' which is prohibitively slow on a file this size.
load_elsst <- function(path) {
  stopifnot(file.exists(path))
  doc <- xml2::read_xml(path)

  ns <- c(
    rdf  = "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    skos = "http://www.w3.org/2004/02/skos/core#",
    dct  = "http://purl.org/dc/terms/",
    owl  = "http://www.w3.org/2002/07/owl#"
  )

  concepts <- xml2::xml_find_all(
    doc,
    ".//rdf:Description[rdf:type/@rdf:resource='http://www.w3.org/2004/02/skos/core#Concept']",
    ns
  )

  id <- xml2::xml_attr(concepts, "about")

  tibble::tibble(
    id = id,
    uuid = sub(".*/", "", id),
    pref_en       = purrr::map_chr(concepts, xml_first_text_in_lang, "./skos:prefLabel",  "en", ns),
    alt_en        = purrr::map(    concepts, xml_all_text_in_lang,   "./skos:altLabel",   "en", ns),
    definition_en = purrr::map_chr(concepts, xml_first_text_in_lang, "./skos:definition", "en", ns),
    broader  = purrr::map(concepts, xml_all_attr, "./skos:broader",  "resource", ns),
    narrower = purrr::map(concepts, xml_all_attr, "./skos:narrower", "resource", ns),
    related  = purrr::map(concepts, xml_all_attr, "./skos:related",  "resource", ns),
    top_concept = purrr::map_lgl(
      concepts,
      ~ length(xml2::xml_find_all(.x, "./skos:topConceptOf", ns)) > 0
    ),
    modified = purrr::map_chr(concepts, xml_first_text, "./dct:modified", ns)
  )
}
