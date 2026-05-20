#' Parse the OntoPop OWL file into a tidy tibble.
#'
#' One row per named owl:Class (anonymous Restriction classes are filtered
#' out by requiring `rdf:about`). The IUSSP-style code (e.g. `101-4`) is
#' split into a `section` ("101") prefix for coarse topic grouping.
#' English definitions come from `ontoPop:definedInContext`.
#'
#' Uses a fixed namespace map for XPath rather than `xml_ns_strip()`,
#' which is prohibitively slow on a file this size.
load_ontopop <- function(path) {
  stopifnot(file.exists(path))
  doc <- xml2::read_xml(path)

  ns <- c(
    rdf     = "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    rdfs    = "http://www.w3.org/2000/01/rdf-schema#",
    owl     = "http://www.w3.org/2002/07/owl#",
    skos    = "http://www.w3.org/2004/02/skos/core#",
    ontoPop = "http://www.semanticweb.org/altergc/ontologies/2025/5/ontoPop#"
  )

  classes <- xml2::xml_find_all(doc, ".//owl:Class[@rdf:about]", ns)

  id <- xml2::xml_attr(classes, "about")
  code <- sub(".*#", "", id)

  tibble::tibble(
    id = id,
    code = code,
    section = sub("-.*", "", code),
    pref_en          = purrr::map_chr(classes, xml_first_text_in_lang, "./skos:prefLabel",            "en", ns),
    alt_en           = purrr::map(    classes, xml_all_text_in_lang,   "./skos:altLabel",             "en", ns),
    definition_en    = purrr::map_chr(classes, xml_first_text_in_lang, "./ontoPop:definedInContext", "en", ns),
    is_defined_by_en = purrr::map_chr(classes, xml_first_text_in_lang, "./rdfs:isDefinedBy",         "en", ns),
    parents = purrr::map(classes, xml_all_attr, "./rdfs:subClassOf", "resource", ns)
  )
}
