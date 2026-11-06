#' Parse the OntoPop OWL file into a tidy tibble.
#'
#' One row per named owl:Class (anonymous Restriction classes are filtered
#' out by requiring `rdf:about`). The IUSSP-style code (e.g. `101-4`) is
#' split into a `section` ("101") prefix for coarse topic grouping.
#' English definitions come from `ontoPop:definedInContext`.
#'
#' `pref_en` is the English `skos:prefLabel` where present, falling back to
#' the class's `rdfs:label` otherwise. 70 classes (mostly sections 180, 380,
#' 580, 680, 880) carry only an `rdfs:label` and no `skos:prefLabel @en`;
#' every `rdfs:label` in the file is untyped English (it equals the English
#' prefLabel on classes that have both), so it is a safe fallback. The
#' `label_source` column flags which field supplied `pref_en`, and the raw
#' `pref_skos_en` / `rdfs_label` columns are kept for provenance.
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

  # English label, with rdfs:label fallback (see roxygen note above).
  pref_skos  <- purrr::map_chr(classes, xml_first_text_in_lang, "./skos:prefLabel", "en", ns)
  rdfs_label <- purrr::map_chr(classes, xml_first_text,         "./rdfs:label",           ns)
  blank      <- function(x) is.na(x) | !nzchar(trimws(x))      # treat "" as missing
  pref_skos[blank(pref_skos)]   <- NA_character_
  rdfs_label[blank(rdfs_label)] <- NA_character_
  pref_en      <- ifelse(!is.na(pref_skos), pref_skos, rdfs_label)
  label_source <- ifelse(!is.na(pref_skos),  "skos:prefLabel",
                  ifelse(!is.na(rdfs_label), "rdfs:label", NA_character_))

  tibble::tibble(
    id = id,
    code = code,
    section = sub("-.*", "", code),
    pref_en          = pref_en,
    pref_skos_en     = pref_skos,
    rdfs_label       = rdfs_label,
    label_source     = label_source,
    alt_en           = purrr::map(    classes, xml_all_text_in_lang,   "./skos:altLabel",             "en", ns),
    definition_en    = purrr::map_chr(classes, xml_first_text_in_lang, "./ontoPop:definedInContext", "en", ns),
    is_defined_by_en = purrr::map_chr(classes, xml_first_text_in_lang, "./rdfs:isDefinedBy",         "en", ns),
    parents = purrr::map(classes, xml_all_attr, "./rdfs:subClassOf", "resource", ns)
  )
}
