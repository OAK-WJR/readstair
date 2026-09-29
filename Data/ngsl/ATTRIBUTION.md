# Attribution: New General Service List 1.2

`NGSL_12_stats.csv` and `NGSL_12_lemmatized_for_research.csv` are the **New General Service List (NGSL) 1.2** by
Browne, C., Culligan, B., and Phillips, J., downloaded on 2026-09-22 from
https://www.newgeneralservicelist.com/new-general-service-list and copied unchanged. The site states: "New General
Service List by Browne, C., Culligan, B., and Phillips, J. is licensed under a Creative Commons Attribution-ShareAlike
4.0 International License" (https://creativecommons.org/licenses/by-sa/4.0/).

| File | Bytes | sha256 |
|---|---|---|
| `NGSL_12_stats.csv` | 62,566 | `2098bab8955a120a9766c6282a51d7d578c6cb0a7d946600d2ffb73ba25a0b44` |
| `NGSL_12_lemmatized_for_research.csv` | 89,485 | `d814f2a0a3c61479a2c5ad037661719a0cc6e7dbcde31f181b54f12d0f1e11a4` |

## Use in ReadStair

`tools/make-lexicon.py` checks both sha256 values, then reads each headword's rank and adjusted frequency per million
(U) from `NGSL_12_stats.csv`, and each headword's word family (the forms listed after it) from
`NGSL_12_lemmatized_for_research.csv`. With them it:

- chooses between the lemmas that WordNet's irregular forms and suffix rules propose for a form (saw: see, not saw).
  NGSL never creates a mapping by itself;
- checks the build: NGSL's most frequent words must land in the lexicon's first bands;
- picks the vocabulary-test words of bands 1-3.

NGSL never sets a band. The research list describes itself as "not for pedagogical purposes"; it groups forms by
spelling "irrespective of meaning sense", which is why it only chooses between proposals.
