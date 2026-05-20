---
output:
  word_document: default
  html_document: default
  pdf_document: default
---
# OntoPop ↔ ELSST linking plan

A staged plan for mapping concepts from the OntoPop population ontology to
the European Language Social Science Thesaurus (ELSST). Mapping is based on
English labels and definitions; later phases combine deterministic string
matching, fuzzy matching, embedding similarity, and LLM adjudication, with
human review at the end.

## Source vocabularies

**ELSST R6** (`ELSST_R6.rdf`) — SKOS thesaurus, ~3,470 concepts under
`https://elsst.cessda.eu/id/6/{uuid}`. Each concept carries multilingual
`skos:prefLabel` / `skos:altLabel` (English prefLabels are UPPERCASE,
e.g. `TEACHING PROFESSION`), often a `skos:definition`, and SKOS
`broader` / `narrower` / `related` links. Broad social-science coverage,
demography included.

**OntoPop** (`OntoPop_RDF-XML_20260327.owl`) — OWL ontology, ~1,645 named
classes with IUSSP-style codes (`101-1`, `101-4`, …) organised by
`rdfs:subClassOf`. ~1,575 English `skos:prefLabel`s (lowercase, e.g.
`demography`, `population`, `inhabitant`), some `skos:altLabel`s, and rich
per-language `ontoPop:definedInContext` paragraphs that define several
related terms together. Narrow demography focus.

The shapes differ (SKOS concept scheme vs. OWL class hierarchy), but both
carry the two fields we need: an English preferred label and English prose
definition / context.

## Direction of mapping

Map **OntoPop → ELSST**: every OntoPop class gets zero or more ELSST
candidates. OntoPop is the smaller, newer vocabulary; many OntoPop terms
will have no good ELSST equivalent and that's fine.

## Phase 0 — Parse to tidy R tables

Read both files with `xml2` (using namespace-aware XPath; `xml_ns_strip()`
is too slow on files this size). Extract one row per concept/class:

- `id`, plus `uuid` (ELSST) or `code` + `section` (OntoPop)
- `pref_en`
- `alt_en` (list-column)
- `definition_en`
- hierarchy (`broader` / `narrower` / `related` for ELSST,
  `parents` for OntoPop)

Cache to `data/cache/elsst.rds` and `data/cache/ontopop.rds` so later
phases load in milliseconds.

**Status:** done. Files: `R/load_elsst.R`, `R/load_ontopop.R`, `R/utils.R`,
`scripts/01_parse.R`.

## Phase 1 — Deterministic string matching

Normalise English labels (lowercase, strip punctuation, singularise with
`textstem`) and look for matches:

1. Exact normalised `pref_en ↔ pref_en`
2. Cross `pref_en ↔ alt_en` and `alt_en ↔ alt_en`
3. Flag 1-to-many hits (e.g. OntoPop has two `population` entries,
   101-3 vs 101-4) for **mandatory** human review — never auto-accept

Output: candidate table tagged `match_source = "exact"`. Should resolve
the bulk of easy cases cheaply.

**Sub-task worth doing here:** the OntoPop `definedInContext` paragraph is
shared across sibling classes (101-1, 101-2, 101-3 all carry the same
text), so each sibling needs a per-concept gloss teased out of it.

The trailing ` - **101-x** ...` bullets turned out to be unreliable — they
exist for only 322 of 1,575 concepts and are often part-of-speech notes
rather than definitions. Instead, every defined term appears inline in the
prose anchored by a `**(code)**` marker. An LLM extractor (one call per
IUSSP section over the 227 shared paragraphs, gpt-4o-mini) produced a
clean standalone definition for **all 1,575** concepts. Files:
`R/llm_gloss.R`, `scripts/04_llm_gloss.R`. Output: `data/gloss_llm.csv`
and a `gloss_llm` column on `data/cache/ontopop.rds`. Cost ~$0.10.

**Status:** done. Files: `R/normalize.R`, `R/extract_gloss.R`,
`scripts/02_string_match.R`. Output: `data/candidates_exact.csv`.

Results: 327 candidate pairs covering 283 / 1,575 OntoPop terms (18%).
Tiers: 169 exact pairs (including 96 exact pref–pref) + 158 stem pairs.
23 ambiguous OntoPop terms (multiple ELSST candidates) flagged for mandatory
human review. 1,292 OntoPop terms unmatched — proceed to Phases 2–3.
Note: `SnowballC` was used for stemming in place of `textstem` (not
installed); stem tier has expected false positives (e.g. `computation` →
COMPUTERS) that human review will catch.

## Phase 2 — Fuzzy string matching

For OntoPop terms still unmatched after Phase 1, use `stringdist` /
`fuzzyjoin` (Jaro-Winkler or token-set ratio) against the full ELSST
label pool. Keep the top ~5 candidates per OntoPop term above a
threshold. These are candidates, not decisions.

**Status:** done. Files: `R/fuzzy_match.R`, `scripts/03_fuzzy_match.R`.
Output: `data/candidates_fuzzy.csv`.

Results: 2,957 candidate pairs covering 942 / 1,292 OntoPop terms left
unmatched by Phase 1. Top ~5 ELSST candidates per term kept at Jaro-Winkler
similarity ≥ 0.85. 350 OntoPop terms still unmatched — proceed to Phase 3.
Note: `fuzzyjoin` was not installed, so `stringdist` was used directly.
Each label is scored twice — on the normalised string and on a token-sorted
variant (words alphabetised, so word-order differences don't penalise) —
keeping the higher. Expected false positives (e.g. `recognition` →
PRECOGNITION, `field worker` → FIELD WORK) carry forward to Phases 4–5.

## Phase 3 — Semantic candidate generation via embeddings

Many true matches aren't string-similar (`inhabitant` ↔ `RESIDENTS`,
`sub-population` ↔ `POPULATION GROUPS`). Embed `pref_en + definition_en`
for every concept on both sides — OpenAI `text-embedding-3-small` via
`ellmer` or `httr2`, or a local sentence-transformers model via
`reticulate`. Take cosine top-k (k≈10) per OntoPop term and merge with
the fuzzy candidates from Phase 2.

**Status:** done. Files: `R/embed.R`, `scripts/05_embed_match.R`.
Output: `data/candidates_semantic.csv`, `data/candidates_phase3.csv`.

Results: embedded all 3,470 ELSST concepts (`pref_en + definition_en`,
label-only where no definition) and the 1,292 OntoPop terms unmatched by
Phase 1 (`pref_en + gloss_llm`) with `text-embedding-3-small` via `httr2`;
embeddings cached to `data/cache/emb_*.rds`. Cosine top-10 ELSST per
OntoPop term → 12,920 semantic pairs. Merged with the Phase 2 fuzzy
candidates into a single shortlist (`data/candidates_phase3.csv`): 14,709
pairs covering all 1,292 terms — 1,168 found by both methods, 1,789 fuzzy
only, 11,752 semantic only. Each row carries `jw_sim`, `cos_sim`, and a
`provenance` tag for Phase 4. Embedding cost ~$0.002.

## Phase 4 — LLM adjudication of candidate pairs

For each OntoPop term with a shortlist of candidates, send one prompt per
term to an LLM containing both definitions, asking it to label each
candidate as one of:

- `exactMatch`
- `closeMatch`
- `broadMatch`
- `narrowMatch`
- `relatedMatch`
- `none`

Plus a one-sentence rationale. Require structured JSON output so it
parses straight back into R. This step bridges "similar but not
identical" cases — exactly what an LLM is good at and code isn't.

- Batch via `ellmer` / `httr2`
- Cache responses keyed by `(ontopop_id, elsst_id)` so reruns are cheap
- Treat the LLM's labels as **suggestions**, not final decisions

Rough budget: ~1,500 OntoPop terms × ~10 candidates ≈ 15k pair
judgments; batch ~10 candidates per prompt to keep cost in the low tens
of dollars on a mid-tier model.

**Status:** done. Files: `R/openai_batch.R`, `scripts/06_adjudicate.R`.
Output: `data/candidates_phase4.csv`.

Results: 14,709 candidate pairs (all 1,292 OntoPop terms from the Phase 3
shortlist) adjudicated by `gpt-4o`, one prompt per term, ~11 candidates
each, structured JSON out. Match-type breakdown: 43 exactMatch,
196 closeMatch, 2,198 broadMatch, 794 narrowMatch, 2,666 relatedMatch,
8,812 none. 1,265 / 1,292 terms got at least one non-`none` candidate;
215 terms have an exact/closeMatch. Every response parsed cleanly.
Note: the org's gpt-4o Batch API enqueued-token limit (90k) is far below
this job's ~611k input tokens, so `06_adjudicate.R` splits the work into
10 sub-batches under that cap and submits them sequentially — a resumable
state machine in `data/cache/batch_phase4.rds`. Candidates are passed as
numbered list items and the model returns the number, so verdicts join
back to ELSST ids deterministically. LLM labels are suggestions for
Phase 5, not decisions — spot checks show some generous exactMatch calls
(e.g. `nucleus` → NUCLEAR FAMILY) that human review will downgrade.

## Phase 5 — Human review

Produce one review CSV: one row per `(OntoPop term, candidate)` pair,
with definitions from both sides, the LLM's proposed mapping type +
rationale, and a blank `reviewer_decision` column.

A small Shiny app speeds review considerably (side-by-side panes,
keyboard accept/reject, progress bar) — worth the ~day of work given
1,500+ terms. Sort by LLM confidence so the easy confirmations clear
quickly and attention goes to the ambiguous cases.

Optional simplification: do binary review first (match / no match), then
classify SKOS type only on accepted pairs. Faster for reviewers.

**Status:** done. Files: `R/review_template.html`,
`scripts/07_build_review.R`. Output: `data/review.html`.

Instead of a Shiny app, the interface is a single self-contained HTML
file — no server and no R needed to run it, so it can be emailed to
reviewers and opened in any browser. One screen per OntoPop term — all
1,575 of them: 155 Phase 1 exact-label matches first, then the 1,292
Phase 4 LLM-adjudicated terms ordered easiest-first (those carrying a
strong gpt-4o match), then the 128 Phase 1 stem matches (heuristic, more
false-positive prone) at the end. Phase 1 candidates carry a synthesised
rationale (`Phase 1 <tier>-tier match (…)`) so the reviewer assigns the
SKOS relation in the same interface; every candidate card also lists
**`exact_partners`** — any *other* OntoPop term that exact-matched the
same ELSST concept in Phase 1, rendered as clickable links that jump
straight to that term's review screen (so reviewing `nucleus` with
NUCLEAR FAMILY as a candidate shows the link to `nuclear family
(113-1)`'s own screen).
Each screen shows the OntoPop label, the term-specific `gloss_llm`, the
full `definedInContext` paragraph (collapsible), and every candidate as a
card: ELSST prefLabel linked to its `elsst.cessda.eu` concept page, the
ELSST definition where one exists, gpt-4o's match type + rationale, and
the JW / cosine scores. Per-candidate buttons let the reviewer confirm or
override the SKOS relation; `none`-rated candidates are tucked behind a
toggle. A search box (press `/` to focus) matches against OntoPop labels,
codes, glosses, the shared definedInContext, and every ELSST candidate
label — so finding the review screen for an ELSST term the reviewer
spotted in another term's context is one keystroke away. Digit-leading
queries (e.g. `113-1`) are detected as code searches and restricted to
code hits, so they don't drown in `definedInContext` mentions of that
code in sibling concepts. The header also shows `position N / total` so
the reviewer always sees where they are in the sequence, separate from
the count of terms marked reviewed. Progress
autosaves to browser `localStorage`, with JSON
save/load for portability and a CSV export (one row per pair, with
`reviewer_decision`) that feeds Phase 6.

## Phase 6 — Emit final mapping

Two outputs:

- A plain CSV for the team (`ontopop_id`, `ontopop_label`, `elsst_id`,
  `elsst_label`, `match_type`, `provenance`, `reviewer`)
- A SKOS mapping file (Turtle or RDF/XML) using `skos:exactMatch`,
  `skos:closeMatch`, etc., publishable alongside OntoPop

## R packages

`xml2`, `dplyr`, `stringr`, `textstem`, `stringdist`, `fuzzyjoin`,
`ellmer` (Anthropic / OpenAI bindings), `shiny`, `rdflib` (optional, for
emitting SKOS).

## Open decisions

- **Match-type granularity** — five SKOS relations vs. binary
  match/no-match. Easier to review binary first, then label type on
  accepted pairs only.
- **Coverage of OntoPop classes without English prefLabel** — 70 of 1,645
  OntoPop classes lack `skos:prefLabel @en`. Decide whether to skip,
  back off to another language, or flag them for manual labelling
  upstream.
- **Definition sparsity in ELSST** — only ~26% of ELSST concepts have an
  English `skos:definition`. Phase 4 prompts will need to fall back to
  prefLabel + altLabels for the rest.
