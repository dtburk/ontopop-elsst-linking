#' Canonical match-type criteria (iteration 2, change 3).
#'
#' Single source of truth shared by the Phase 4 LLM adjudicator prompt
#' (`scripts/06_adjudicate.R`) and the Phase 5 human-review interface
#' (`scripts/07_build_review.R`), so the model and the human reviewers apply
#' identical standards. Edit the criteria here only.

# Per-type one-line definitions, in confidence order.
MATCH_TYPE_DEFS <- c(
  exactMatch   = "the same concept; interchangeable in all contexts",
  closeMatch   = "nearly the same; interchangeable in most contexts",
  broadMatch   = "the candidate is broader (more general) than the source",
  narrowMatch  = "the candidate is narrower (more specific) than the source",
  relatedMatch = "associated, but neither equivalent nor hierarchical",
  none         = "no meaningful relationship"
)

# The stricter assignment rules. Kept as plain prose so it drops cleanly into
# both an LLM prompt and (lightly formatted) the review HTML.
MATCH_TYPE_RULES <- paste(
  "RULES for assigning match types:",
  "",
  "1. SAME TYPE OF ENTITY. exactMatch, closeMatch, broadMatch and narrowMatch",
  "   may only link two concepts that denote the SAME KIND of entity. When the",
  "   two concepts are different kinds of thing, the strongest label allowed is",
  "   relatedMatch. Example: \"older generation\" is NOT a closeMatch for \"old",
  "   age\" — a generation is a group of people, whereas an age (or life stage)",
  "   is not the same kind of entity — so they are at most relatedMatch.",
  "",
  "2. narrowMatch (candidate narrower than the source) is valid only if the",
  "   candidate is, with respect to the source, one of:",
  "     (a) a specific TYPE of the source,",
  "     (b) a PART or ELEMENT of the source, or",
  "     (c) a specific INSTANCE of the source.",
  "",
  "3. broadMatch (candidate broader than the source) applies the same three",
  "   criteria in reverse: the SOURCE must be a type, part/element, or instance",
  "   of the candidate.",
  "",
  "4. Use relatedMatch for genuine but non-hierarchical or cross-type",
  "   associations, and none when there is no useful relationship.",
  sep = "\n")
