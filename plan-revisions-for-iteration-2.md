# Revisions to implement for second iteration of linking

1. Both OntoPop (with subClassOf) and ELSST (with broader and narrower concepts) 
   define hierarchical relationships, and these hierarchically related terms 
   often help clarify the meaning of a term. In the creation of the initial 
   tidy dataset, harvest that information so that it can be displayed to the 
   human reviewer in Phase 5. For OntoPop, capture all "ascendant" (higher in 
   the hierarchy) classes plus all direct children of a class. For ELSST, 
   capture all "ascendant" concepts (broader concepts all the way up to the top 
   of the hierarchy) plus the first level of narrower concepts. These classes 
   or concepts will be used as additional text for the vector embeddings and 
   will be displayed to human reviewers as helpful context for reviewing links.
2. It's fine to keep Phase 1, but don't remove any OntoPop classes even if they 
   have an exact match -- I want string-distance- and embeddings-based 
   candidates for all OntoPop classes, because the exact matches are sometimes 
   false positives.
3. Add more detailed instructions for the LLM adjudicator about how to assign 
   match types, and include a version of these instructions in the review HTML 
   interface to remind human reviewers of the criteria. All match types other 
   than relatedMatch should only be used for classes/concepts that are the same 
   type of entity -- for example, "older generation" cannot be a closeMatch for 
   "old age", because a generation is not the same type of thing as a person's 
   age or a stage of life. Moreover, any narrowMatch should should satisfy one 
   of the following criteria: (1) it is a specific *type* of the broader term, 
   (2) it is a *part* or *element* of the broader term, or (3) it is a specific
   *instance* of the broader term. The same criteria apply in reverse for 
   broadMatch.
4. In addition to the HTML interface changes mentioned above (show the 
   ascendants and one generation of descendants for every term, include 
   reminders about the criteria for each type of match), could the interface 
   also show, for each ELSST candidate term, what other OntoPop terms it has 
   been matched to, with the match type? For example, for 
   ontopop:traditional family <-> elsst:nuclear family, the human reviewer would 
   see that elsst:nuclear family has also been suggested as an exactMatch to 
   ontopop:nuclear family.
