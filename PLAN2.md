---
output:
  word_document: default
  html_document: default
  pdf_document: default
---
# OntoPop ↔ ELSST linking plan — iteration 2

A staged plan for mapping concepts from the OntoPop population ontology to
the European Language Social Science Thesaurus (ELSST). Mapping is based on
English labels and definitions; later phases combine deterministic string
matching, fuzzy matching, embedding similarity, and LLM adjudication, with
human review at the end.

**This plan supersedes `PLAN.md` for the second iteration.** It keeps the
same six-phase shape but folds in four revisions requested after the first
full run (see `plan-revisions-for-iteration-2.md`):

1. **Harvest hierarchy context** for both vocabularies in Phase 0 — for each
   term, its ascendants (and one generation of descendants) — and reuse it
   both as embedding text (Phase 3) and as reviewer context (Phase 5).
2. **Keep every OntoPop class in the candidate pool**, even ones with an
   exact label match in Phase 1, because exact matches are sometimes false
   positives. Phase 1 now annotates rather than removes.
3. **Tighten the match-type rules** given to the LLM adjudicator (Phase 4),
   and surface those same rules to human reviewers (Phase 5).
4. **Richer review interface** (Phase 5): show each term's hierarchy context,
   the match-type criteria, and — for every ELSST candidate — which other
   OntoPop terms it was matched to and at what match type.

The iteration-1 outputs (all of `data/`, including `data/cache/`) have been
moved to **`data/iteration1/`** so nothing is lost. Iteration 2 regenerates
`data/cache/` and the `data/` outputs from the source files in the repo root.
Because the hierarchy context feeds the embeddings (change 1), the candidate
pool grows (change 2), and the adjudicator prompt changes (change 3),
everything from Phase 0 downstream is regenerated this iteration; only the
source RDF/OWL files are reused.

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
definition / context — and both define a hierarchy we now exploit
(`skos:broader`/`narrower` for ELSST, `rdfs:subClassOf` for OntoPop).

## Direction of mapping

Map **OntoPop → ELSST**: every OntoPop class gets zero or more ELSST
candidates. OntoPop is the smaller, newer vocabulary; many OntoPop terms
will have no good ELSST equivalent and that's fine.

## Phase 0 — Parse to tidy R tables (+ hierarchy context)

Read both files with `xml2` (using namespace-aware XPath; `xml_ns_strip()`
is too slow on files this size). Extract one row per concept/class:

- `id`, plus `uuid` (ELSST) or `code` + `section` (OntoPop)
- `pref_en` — for OntoPop, the English `skos:prefLabel` where present,
  else a fallback to the class's `rdfs:label` (see note below); a
  `label_source` column flags which field supplied it, and raw
  `pref_skos_en` / `rdfs_label` are kept for provenance
- `alt_en` (list-column)
- `definition_en`
- raw hierarchy links (`broader` / `narrower` / `related` for ELSST,
  `parents` for OntoPop) — already extracted as resource-id list-columns
  in iteration 1 (`R/load_elsst.R`, `R/load_ontopop.R`).

**New in iteration 2 — derived hierarchy context.** After the raw parse,
resolve the link graphs into human-readable context columns, stored as
ordered list-columns of `{id, label}` (label = `pref_en`, lowercased for
OntoPop, title/normal case for ELSST):

- **OntoPop** (`rdfs:subClassOf` graph):
  - `ascendants` — *all* ancestor classes from the direct parent up to the
    root, nearest-first. Resolve the transitive closure of `parents`,
    guarding against cycles and the `owl:Thing` root.
  - `children` — *all direct* subclasses (the inverse of `parents`: every
    class whose `parents` contains this `id`). One generation only.
- **ELSST** (`skos:broader` / `narrower` graph):
  - `ascendants` — *all* broader concepts from the direct broader up to the
    top concept(s), nearest-first (transitive closure of `broader`).
  - `narrower_1` — the *first level* of narrower concepts only (this is the
    existing `narrower` column, resolved to labels). One generation.

Build a `{id → pref_en}` lookup once per vocabulary and a child index for
OntoPop (group ids by each parent). Keep cycle/visited guards: real
thesauri occasionally contain loops.

These context columns serve two consumers:

- **Phase 3 embeddings** — appended to the embedding text (see Phase 3) so
  semantically similar but string-dissimilar terms cluster by their
  neighbourhood, not just their own label/definition.
- **Phase 5 review UI** — displayed to the reviewer as ascendants + one
  generation of descendants for each term and each candidate (see Phase 5).

**OntoPop label fallback (`rdfs:label`).** 70 of 1,645 OntoPop classes have
no `skos:prefLabel @en` — they cluster in sections 180 (35), 680 (11), 580
(7), 380 (6), 224 (5), 880 (4), 480/780 (1 each). None are truly label-less:
all 70 carry an English `rdfs:label` (e.g. `180-1` = "demographic concepts",
`380-3` = "gender"). Every `rdfs:label` in the file is untyped and equals the
English prefLabel on classes that have both, so `pref_en` falls back to it
when `skos:prefLabel @en` is absent. This recovers usable labels for all 70,
so they flow through Phases 1–4 like every other class (consistent with the
keep-every-class goal of change 2). `label_source ∈ {"skos:prefLabel",
"rdfs:label"}` lets Phase 5 flag fallback-labelled terms to reviewers, and
they have no `definedInContext` definition so the hierarchy context (change 1)
is their main disambiguating signal.

Cache to `data/cache/elsst.rds` and `data/cache/ontopop.rds` (now carrying
the derived context columns) so later phases load in milliseconds.

**Status:** done (iteration 2). Files: `R/load_ontopop.R` (rdfs:label
fallback), `R/hierarchy.R` (resolver), `scripts/01_parse.R` (wiring + stats).
Each context column is a list-column of one `tibble(id, label)` per row, so
it serialises to a JSON array of `{id, label}` for Phase 5 and is easy to
fold into embedding text in Phase 3. Resolvers do a level-by-level BFS over
the (multi-parent) DAGs — nearest-first, deduped across paths, cycle-guarded;
anonymous `subClassOf` restriction targets (217 of 2,018 OntoPop links) are
dropped. Observed: OntoPop ascendant depth 0–21 (2 roots, 1,251 leaves,
≤40 children); ELSST ascendant depth 0–10 (249 top concepts have none,
2,446 leaves have no `narrower_1`). All parent/broader links resolve to
known nodes.

## Phase 1 — Deterministic string matching (annotate, don't prune)

Normalise English labels (lowercase, strip punctuation, singularise with
`SnowballC`/`textstem`) and look for matches:

1. Exact normalised `pref_en ↔ pref_en`
2. Cross `pref_en ↔ alt_en` and `alt_en ↔ alt_en`
3. Flag 1-to-many hits (e.g. OntoPop has two `population` entries,
   101-3 vs 101-4) for **mandatory** human review — never auto-accept

Output: candidate table tagged `match_source = "exact"` / tier.

**Changed in iteration 2 (change 2):** Phase 1 no longer *removes* matched
OntoPop terms from the downstream pool. **Every OntoPop class flows through
Phases 2–4** and gets string-distance and embedding candidates, because
exact label matches are sometimes false positives (e.g. two senses sharing
a label). The Phase 1 exact/stem hits are retained as an *additional*,
pre-labelled candidate source merged into the Phase 3 shortlist (tagged
`provenance = "phase1:<tier>"`, default suggestion `exactMatch`), so they
appear alongside the fuzzy/semantic candidates for the same term and are
adjudicated and reviewed like any other candidate — never silently
auto-accepted.

Carried over from iteration 1 — the OntoPop `definedInContext` paragraph is
shared across sibling classes (101-1, 101-2, 101-3 share the same text), so
each sibling needs a per-concept gloss teased out of it. An LLM extractor
(one call per IUSSP section over the shared paragraphs, `gpt-4o-mini`)
produces a clean standalone `gloss_llm` for every concept. This step is
unchanged by the four revisions; it can be re-run, or `gloss_llm` lifted
from `data/iteration1/` to save the ~$0.10. Files: `R/llm_gloss.R`,
`scripts/04_llm_gloss.R`. Output: `data/gloss_llm.csv` and a `gloss_llm`
column on `data/cache/ontopop.rds`.

**Status:** done (iteration 2). `scripts/02_string_match.R` itself needed no
change — it already emitted all exact/stem pairs without pruning; the pruning
lived *downstream* (Phases 2–3 read this file to exclude matched terms), and
that is where the pooling change was made. `candidates_exact` is now a
candidate *source*, not a removal list. Files: `R/normalize.R`,
`R/extract_gloss.R`, `scripts/02_string_match.R`. Output:
`data/candidates_exact.csv`. Re-run results: 335 pairs over 291 OntoPop terms
(174 exact, 161 stem).

## Phase 2 — Fuzzy string matching

For **all** OntoPop terms (change 2 — no longer only the Phase-1
unmatched), use `stringdist` (Jaro-Winkler, scored on both the normalised
string and a token-sorted variant, keeping the higher) against the full
ELSST label pool. Keep the top ~5 candidates per OntoPop term above a
threshold (≈ 0.85). These are candidates, not decisions.

**Status:** done (iteration 2). `scripts/03_fuzzy_match.R` no longer reads
`candidates_exact` or filters out Phase-1 matches — it runs over all 1,645
labelled terms. Files: `R/fuzzy_match.R`, `scripts/03_fuzzy_match.R`.
Output: `data/candidates_fuzzy.csv`. Re-run results: 1,277 / 1,645 terms get
≥1 fuzzy candidate; all 291 Phase-1-matched terms now also receive fuzzy
candidates (vs 0 in iteration 1), including 169 JW=1.0 exact-label pairs that
iteration 1 would have pruned — exactly the false-positive-prone exact matches
change 2 wants surfaced for review.

## Phase 3 — Semantic candidate generation via embeddings (+ hierarchy text)

Many true matches aren't string-similar (`inhabitant` ↔ `RESIDENTS`,
`sub-population` ↔ `POPULATION GROUPS`). Embed every concept on both sides
with OpenAI `text-embedding-3-small` (via `httr2`), take cosine top-k
(k≈10) per OntoPop term, and merge with the Phase 2 fuzzy candidates and
the Phase 1 label matches into one shortlist.

**Changed in iteration 2 (change 1):** the embedding text now includes the
harvested hierarchy context, so a term is embedded with the company it
keeps. Proposed text composition:

- **OntoPop:** `pref_en` + `gloss_llm` + `ascendants` labels + `children`
  labels.
- **ELSST:** `pref_en` + `definition_en` (label-only where no definition) +
  `ascendants` labels + `narrower_1` labels.

**Ascendant cap for embedding text — `N = 4` (decided).** Use only the
**nearest 4 ascendants** in the embedding text (the resolver stores them
nearest-first, so this is `head(ascendants, 4)`). Rationale from the
distribution: ELSST chains are shallow, so N=4 captures the complete chain
for 94% of concepts; OntoPop chains are deep (up to 21) and cross-facet, but
the *nearest* ancestors are the direct parents (the relevant ones) while the
long tail is cross-facet noise (e.g. `legitimate child` accumulates a
measurement branch — "data set", "variate", "measure" — at depth 5+), so
capping at 4 keeps the signal and sheds the noise by design. The cap is
**embedding-only**; the Phase 5 review UI shows the **full** chain (display,
not signal — a human can ignore noise a model can't). `children` /
`narrower_1` are single-generation; they are **count-capped at 12** in the
embedding text (`N_DESC = 12`) — the 95th percentile is ~12, so this only
trims the long tail (up to 40 children / 39 narrower) while leaving the median
2–3 untouched. The UI lists them in full.

Use clear separators/prefixes (e.g. `Broader: …` / `Narrower: …`) so the
context reads as structure, not noise. Embed **all** OntoPop terms (change
2). Cache embeddings to `data/cache/emb_*.rds`. Because the input text
changed, iteration-1 embedding caches are not reused.

**Status:** code complete, run pending (iteration 2). **Done:** (a) the
pooling/merge change in `scripts/05_embed_match.R` — embeds all labelled terms
(no Phase-1 pruning) and folds the Phase 1 exact/stem pairs into the shortlist
as a third source; the merged shortlist carries `from_phase1` / `from_fuzzy` /
`from_semantic` flags, a combined `provenance` (e.g. `phase1+fuzzy`, `phase1`,
`phase1+fuzzy+semantic`), and a `phase1_tier` column; Phase-1-only pairs are
retained even when fuzzy/semantic miss them. (b) the hierarchy embedding text
(change 1) — `build_embed_text()` in `R/embed.R` composes `label` +
definition/gloss + `Broader:` (nearest `N_ASC = 4` ascendants) + `Narrower:`
(`N_DESC = 12` descendant generation); empty sections are omitted, so
label-only `rdfs:label` terms read as label + hierarchy. Both caps and the
merge were unit-tested on the cached tables. **Run complete:** embedded all
1,645 OntoPop terms + 3,470 ELSST concepts; merged shortlist has **19,022
pairs over all 1,645 terms** (avg 11.6 each) — 14,781 semantic-only, 2,533
fuzzy-only, 1,387 fuzzy+semantic, 321 with a Phase 1 tier (168 exact, 153
stem). The 70 `rdfs:label`-only terms each drew ~11.6 candidates on label +
hierarchy alone. Files: `R/embed.R`, `scripts/05_embed_match.R`. Output:
`data/candidates_semantic.csv`, `data/candidates_phase3.csv`.

## Phase 4 — LLM adjudication of candidate pairs (stricter rules)

For each OntoPop term with a shortlist of candidates, send one prompt per
term to an LLM containing both definitions **and the hierarchy context for
both sides**, asking it to label each candidate as one of:

- `exactMatch`
- `closeMatch`
- `broadMatch`
- `narrowMatch`
- `relatedMatch`
- `none`

plus a one-sentence rationale, as structured JSON.

**Changed in iteration 2 (change 3) — match-type rules.** The prompt now
spells out, and the model must apply, these criteria. The *same wording* is
surfaced to human reviewers in Phase 5 (single source of truth):

1. **Same type of entity required for all matches except `relatedMatch`.**
   `exactMatch`, `closeMatch`, `broadMatch`, and `narrowMatch` may only link
   two terms that denote the *same kind of thing*. Example of what this
   rules out: *"older generation"* is **not** a `closeMatch` for *"old
   age"* — a generation (a cohort of people) is not the same type of entity
   as an age, a life stage, or a person's age. Cross-type associations like
   that are at most `relatedMatch`.
2. **`narrowMatch` (candidate is narrower than the OntoPop term)** must
   satisfy at least one of:
   - (a) the candidate is a specific **type** of the broader term;
   - (b) the candidate is a **part** or **element** of the broader term;
   - (c) the candidate is a specific **instance** of the broader term.
3. **`broadMatch`** applies the same three criteria *in reverse* (the
   OntoPop term is a type/part/instance of the broader candidate).
4. `relatedMatch` is the catch-all for genuine but non-hierarchical,
   possibly cross-type associations; `none` when there is no useful link.

Operational notes (carried over): batch via `httr2`; cache responses keyed
by `(ontopop_id, elsst_id)` so reruns are cheap; pass candidates as a
numbered list and have the model return the number so verdicts join back to
ELSST ids deterministically; respect the org's Batch API enqueued-token cap
by splitting into sub-batches submitted sequentially via a resumable state
machine in `data/cache/batch_phase4.rds`. Treat all labels as
**suggestions**, not final decisions.

**Status:** code complete, run pending (iteration 2). **Done:** (a) the
match-type rules (change 3) are factored into `R/match_rules.R` as
`MATCH_TYPE_DEFS` + `MATCH_TYPE_RULES` — a single source of truth that
`scripts/06_adjudicate.R` injects into the prompt and
`scripts/07_build_review.R` will render into the Phase 5 HTML; the system
message instructs the model to apply them strictly. (b) the hierarchy context
in the prompt (change 1's adjudication half) — the state-build step joins
capped `Broader:`/`Narrower:` label strings (`ASC_CAP = 4`, `DESC_CAP = 6`)
for the source (OntoPop `ascendants`/`children`) and each candidate (ELSST
`ascendants`/`narrower_1`) from the cache tables, and `build_user_msg` renders
them with a note telling the model to use them for entity-type and hierarchy
judgments. `hierarchy_labels()` moved to `R/hierarchy.R` (shared by Phases
3/4/5). The full term set (change 2) flows in via `candidates_phase3`. Prompt
rendering and script parse verified. **Run complete:** all 19,022 pairs
adjudicated by `gpt-4o` across 24 sub-batches (~1.84M input tokens; the rules
+ hierarchy roughly tripled iteration 1's 611k). Breakdown: 9,618 none, 5,908
relatedMatch, 2,094 broadMatch, 1,068 narrowMatch, 180 exactMatch, 154
closeMatch; **0 unparsed**; 326 terms with ≥1 exact/close. The much larger
relatedMatch share vs iteration 1 (5,908 vs 2,666) reflects the change-3
same-entity-type rule demoting cross-type associations. `openai_batch.R`
retry hardened mid-run (max_tries 6; retries 429/500/502/503/504) after a
transient 5xx; the resumable state machine rode it out. Files:
`R/match_rules.R`, `R/hierarchy.R`, `R/openai_batch.R`,
`scripts/06_adjudicate.R`. Output: `data/candidates_phase4.csv`.

## Phase 5 — Human review (richer interface)

A single self-contained HTML file — no server, no R needed to run it, so it
can be emailed to reviewers and opened in any browser. One screen per
OntoPop term. Each screen shows the OntoPop label, term-specific
`gloss_llm`, the full `definedInContext` paragraph (collapsible), and every
candidate as a card (ELSST prefLabel linked to its `elsst.cessda.eu`
page, the ELSST definition, the LLM's match type + rationale, JW / cosine
scores). Per-candidate buttons confirm or override the SKOS relation;
`none`-rated candidates tuck behind a toggle. Search box (`/` to focus),
`position N / total` header, autosave to `localStorage`, JSON save/load, and
CSV export (one row per pair with `reviewer_decision`) feeding Phase 6.

**New in iteration 2:**

- **(change 1) Hierarchy context shown for every term and every candidate.**
  For the OntoPop term: its `ascendants` and `children`. For each ELSST
  candidate: its `ascendants` and `narrower_1`. Render compactly (e.g.
  breadcrumb of ascendants + a short list of one generation of descendants)
  so the reviewer can judge a link in the context of its neighbourhood.
- **(change 3) Match-type criteria reminder.** Display the Phase 4 rules
  (same-type requirement; the type/part/instance test for narrow/broad) in
  the interface — a persistent legend or a per-card tooltip — so reviewers
  apply the same standard the adjudicator was given.
- **(change 4) Cross-references for every candidate, all match types.**
  Generalise iteration 1's `exact_partners` feature: for each ELSST
  candidate, list **all other OntoPop terms it was matched to**, each with
  its match type, as clickable links that jump to that term's screen.
  Example: reviewing `traditional family ↔ nuclear family`, the reviewer
  sees that ELSST `nuclear family` was also suggested as an `exactMatch` to
  OntoPop `nuclear family`. Build this from the Phase 4 results (an
  `elsst_id → [{ontopop_code, ontopop_label, match_type}]` index), filtering
  out the current term, replacing the Phase-1-only `partner_lookup`.

**Status:** code complete, run pending (iteration 2). `scripts/07_build_review.R`
rewritten to read only the Phase 4 shortlist (which now covers every labelled
term), dropping the separate Phase 1 exact/stem sections — those pairs appear
inline, flagged `exact-label` / `stem-label` per the `phase1_tier` carried
through Phase 4 (exact matches are sometimes false positives; stem more so). All three
features are implemented: (1) OntoPop term hierarchy (`ascendants` as a
clickable nearest-first breadcrumb + `children`) linking to other review
screens, and ELSST candidate hierarchy (`ascendants`/`narrower_1`) shown per
card — full chains (display-full); (3) a collapsible match-type criteria panel
rendered from the shared `R/match_rules.R` constants (same wording as the
Phase 4 prompt); (4) per-candidate cross-references to every other OntoPop
term the ELSST concept matched (any non-`none` type), with match type, as
clickable links. To avoid bloat, shared ELSST hierarchy and cross-ref data
live in side dictionaries (`ELSST_CTX`, `XREF`) keyed by ELSST id and looked
up in the page. Filters updated (All / Has exact-close / Exact-label /
Unreviewed / Reviewed). Verified end-to-end on a synthetic Phase 4 input:
valid HTML, 0 leftover placeholders, all JSON blobs parse, hierarchy +
cross-refs populate, easiest-first ordering holds. **Run complete:** built `data/review.html`
(10.8 MB) — 1,645 terms, 19,022 pairs, 2,208 ELSST context entries, 1,276
cross-reference entries. Validated on real data (all JSON parses, no leftover
placeholders, rules panel present); spot-check of `nuclear family` (113-1)
confirms the exact-label tier badge and that ELSST `NUCLEAR FAMILY`'s
cross-reference lists 20 other OntoPop terms it matched, with types. Files:
`R/review_template.html`, `R/match_rules.R`, `R/hierarchy.R`,
`scripts/07_build_review.R`. Output: `data/review.html`.

## Phase 6 — Emit final mapping

Two outputs:

- A plain CSV for the team (`ontopop_id`, `ontopop_label`, `elsst_id`,
  `elsst_label`, `match_type`, `provenance`, `reviewer`)
- A SKOS mapping file (Turtle or RDF/XML) using `skos:exactMatch`,
  `skos:closeMatch`, etc., publishable alongside OntoPop

## R packages

`xml2`, `dplyr`, `stringr`, `textstem` / `SnowballC`, `stringdist`,
`fuzzyjoin` (optional), `httr2`, `jsonlite`, `purrr`, `tibble`,
`rdflib` (optional, for emitting SKOS).

## Open decisions

- **Match-type granularity** — five SKOS relations vs. binary
  match/no-match. The stricter rules (change 3) assume the five-relation
  scheme; reviewers may still collapse to binary first if it's faster.
- ~~**Coverage of OntoPop classes without English prefLabel**~~ —
  *resolved.* The 70 classes lacking `skos:prefLabel @en` all carry an
  English `rdfs:label`; `pref_en` now falls back to it (see Phase 0). No
  classes are dropped for want of a label.
- **Definition sparsity in ELSST** — only ~26% of ELSST concepts have an
  English `skos:definition`; the hierarchy context (change 1) now partly
  compensates by giving even definition-less concepts neighbourhood text.
- ~~**How much hierarchy to embed**~~ — *resolved: `N = 4`, display-full /
  embed-capped* (see Phase 3). Full ascendant chains are long and cross-facet
  (OntoPop reaches depth 21, ELSST ≤10), so the embedding text uses only the
  nearest 4 ascendants while the Phase 5 UI shows the full chain. Same-section
  filtering was rejected (it drops ~50% of classes to zero ancestors because
  only 44% of `subClassOf` edges stay in-section). The resolver stores full
  chains; the cap is applied in Phase 3.
