#!/usr/bin/env Rscript
# Phase 0: parse ELSST and OntoPop into tidy tibbles, cache to RDS.
#
# Run from the project root:
#   Rscript scripts/01_parse.R

suppressPackageStartupMessages({
  library(tibble)
  library(dplyr)
  library(purrr)
  library(xml2)
})

source("R/utils.R")
source("R/load_elsst.R")
source("R/load_ontopop.R")

dir.create("data/cache", recursive = TRUE, showWarnings = FALSE)

elsst_path   <- "ELSST_R6.rdf"
ontopop_path <- "OntoPop_RDF-XML_20260327.owl"

message("Parsing ELSST from ", elsst_path, " ...")
t0 <- Sys.time()
elsst <- load_elsst(elsst_path)
message(sprintf("  %d concepts in %.1fs", nrow(elsst),
                as.numeric(difftime(Sys.time(), t0, units = "secs"))))
saveRDS(elsst, "data/cache/elsst.rds")

message("Parsing OntoPop from ", ontopop_path, " ...")
t0 <- Sys.time()
ontopop <- load_ontopop(ontopop_path)
message(sprintf("  %d classes in %.1fs", nrow(ontopop),
                as.numeric(difftime(Sys.time(), t0, units = "secs"))))
saveRDS(ontopop, "data/cache/ontopop.rds")

cat("\n=== ELSST ===\n")
cat("Concepts:                       ", nrow(elsst), "\n")
cat("With English prefLabel:         ", sum(!is.na(elsst$pref_en)), "\n")
cat("With English definition:        ", sum(!is.na(elsst$definition_en)), "\n")
cat("With >=1 English altLabel:      ", sum(lengths(elsst$alt_en) > 0), "\n")
cat("Top concepts:                   ", sum(elsst$top_concept), "\n")
cat("With >=1 broader link:          ", sum(lengths(elsst$broader) > 0), "\n")

cat("\n=== OntoPop ===\n")
cat("Classes:                        ", nrow(ontopop), "\n")
cat("With English prefLabel:         ", sum(!is.na(ontopop$pref_en)), "\n")
cat("With English definedInContext:  ", sum(!is.na(ontopop$definition_en)), "\n")
cat("With >=1 English altLabel:      ", sum(lengths(ontopop$alt_en) > 0), "\n")
cat("With >=1 parent class:          ", sum(lengths(ontopop$parents) > 0), "\n")
cat("Distinct IUSSP sections:        ", dplyr::n_distinct(ontopop$section), "\n")

cat("\nSample ELSST rows:\n")
print(head(elsst |> dplyr::select(uuid, pref_en, definition_en), 3))
cat("\nSample OntoPop rows:\n")
print(head(ontopop |> dplyr::select(code, pref_en, definition_en), 3))

cat("\nCached to data/cache/elsst.rds and data/cache/ontopop.rds\n")
