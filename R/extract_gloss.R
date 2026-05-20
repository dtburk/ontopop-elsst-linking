#' Extract the per-concept bullet from an OntoPop `definedInContext` paragraph.
#'
#' The English definedInContext paragraph covers a whole IUSSP section and
#' contains per-term bullets of the form:
#'   " - **101-4**  Population, n. - ..."
#'
#' This function pulls just the bullet for `code`, returning the gloss text
#' without the " - **code**  " prefix, or NA if none is found.
extract_gloss_en <- function(code, definition_en) {
  mapply(function(co, def) {
    if (is.na(def) || is.na(co)) return(NA_character_)
    lines <- strsplit(def, "\n")[[1]]
    prefix <- paste0(" - **", co, "**")
    hit <- grep(prefix, lines, fixed = TRUE, value = TRUE)
    if (length(hit) == 0) return(NA_character_)
    # Strip the " - **code**  " leader (with optional extra spaces/bold markers)
    gloss <- sub(paste0("^\\s*-\\s*\\*\\*", gsub("([.-])", "\\\\\\1", co),
                        "\\*\\*\\s*"), "", hit[1])
    # Strip any remaining markdown bold markers from the gloss text
    gloss <- gsub("\\*\\*", "", gloss)
    trimws(gloss)
  }, code, definition_en, SIMPLIFY = TRUE, USE.NAMES = FALSE)
}
