# Attribution: reviewed lemma decisions

`overrides.tsv` lists lemma decisions reviewed by the ReadStair authors. `tools/make-lexicon.py` applies them after every
rule, so they win over the automatic decisions. The file holds no third-party data. It is dedicated to the public domain
under CC0 1.0 Universal (see LICENSE).

Format: UTF-8 with LF line endings, tab-separated, one `#` header line. Columns: `form`; `action`, either `keep` (the
form is its own lemma) or `fold:<lemma>` (the form reads as that lemma); `reason`. The generator stops if a row names a
form that is not in its word list, or has no effect.

`renames.tsv` lists reviewed lemma changes, also written by the ReadStair authors and holding no third-party data, under the
same CC0 1.0 dedication. When a rebuild changes the lemma a form reads as, `tools/make-lexicon.py` stops unless a row
lists that change. Format as above; columns: `form`, `old` lemma, `new` lemma, `reason`.
