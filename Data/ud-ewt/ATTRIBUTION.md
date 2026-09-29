# Attribution: lemma evaluation set

`lemma-500.tsv` holds 500 (form, lemma) pairs that test the lexicon's lookup: 71 rows written for ReadStair
(`source` = `readstair`) and 429 rows taken from the **Universal Dependencies English Web Treebank (UD English-EWT)
v2.18**, released 2026-05-15 (https://github.com/UniversalDependencies/UD_English-EWT; `source` = `ud-ewt-2.18`).
Only words and their lemmas are taken, never sentences.

## License

From the treebank's README: "Universal Dependencies English Web Treebank annotations © 2013-2021 by The Board of
Trustees of The Leland Stanford Junior University. All Rights Reserved. The annotations and database rights of the
Universal Dependencies English Web Treebank are licensed under a Creative Commons Attribution-ShareAlike 4.0
International License." and "The underlying texts come from various sources collected for the LDC English Web Treebank.
Some parts are in the public domain. Portions may be © 2012 Google Inc., © 2011 Yahoo! Inc., © 2012 Trustees of the
University of Pennsylvania and/or © other original authors."

`LICENSE` is the CC BY-SA 4.0 legal code, copied unchanged from the treebank. The whole file, including the ReadStair
rows, is distributed under CC BY-SA 4.0.

## How the rows were chosen

`python3 tools/make-lexicon.py --review OUT --ud DIR` draws the rows from the treebank's CoNLL-U files, after checking
their sha256, and writes them to OUT as a draft with the derived `also` column. It never writes this file, and it reports
whether the draft's `form`, `lemma`, `kind` and `source` columns still match it.

| File | sha256 |
|---|---|
| `en_ewt-ud-train.conllu` | `d68e06122a702464c613076523d56740f047e5bbe89dd90ec32737e04d952143` |
| `en_ewt-ud-dev.conllu` | `39239e0a60db3ae68f4b7036189f11b6692741d10ff8240dd91f74f2760d90f8` |
| `en_ewt-ud-test.conllu` | `fa024f43dc5da3c5ac02563bc9bd0e974f46cbb1560823976a8f342a37dc494a` |

- Words: tagged NOUN, VERB, ADJ, ADV or AUX; not marked `Typo=Yes`, `Abbr=Yes` or with any `Style`; without a
  `CorrectForm`; not a piece of a multiword token (so `wo` from `won't` is out); letters only; lowercased.
- Rows come from the train split only, and only from forms that never occur in dev or test, because those two splits
  were used to choose the generator's constants. A form must occur at least twice, be among wordfreq's 80,000 most
  frequent entries, have no letter three times in a row and match no offensive pattern.
- Strata, each in a fixed order (sha1 of the form): `noun` 145, `verb` 140, `adj-adv` 21 (all there are), `same` 103
  (the form is its own lemma and ends in -s, -ed, -ing, -er, -est or -en) and `homograph` 20 (no lemma has 90% of the
  form's occurrences; the other lemmas with at least 10% go into the draft's `also`). Homograph rows are counted, not
  gated.
- In the draft, `also` lists other lemmas a reader may accept, derived without the lexicon: the NGSL headword of an NGSL
  family member, the American spelling of a British one, and a participle's WordNet verb when UD keeps the participle.
  This file holds the audited values (below).
- The 71 ReadStair rows (`kind` = `trap`) check that the lookup never reads a word as a different, shorter word (wed,
  hiss, james), handles irregular and regular forms (mice, dined, colour), contractions (their parts: `i'd` gives
  `i would|have`), possessives and hyphenated compounds (`rabbit-hole's` gives `rabbit-hole`).

## Audit of `also`

This file is the audited copy and the source of truth. On 2026-09-23 every derived `also` value (54 rows) was checked by
hand against the row's train sentence, from a review list that shows no lexicon output, and one rule: a lemma is
credited only if a learner's dictionary lists the form, in that sentence's sense, under that headword. 21 values were
kept (`travellers`: `traveler`, one headword in two spellings), 1 narrowed (`organised`: `organized`, not the verb
organise/organize) and 32 removed: where the form has its own entry in that sense (delighted, warning, lighting), where
it is the plural of a noun the other lemma is not (meetings is not meet), and, for a homograph, where the other reading
does not fit the sentence. 22 rows have an `also` value.

## Scores, and what is not held out

`tools/make-lexicon.py` scores every build on this file and stops below the floors that U-LEM-001 asserts: at least 97%
of the gated UD rows accepted (the lemma or an audited `also` value) and at least 92% strict (the lemma), every trap
row exact. The rows come from the train split. The reviewed decisions in `Data/lexicon/overrides.tsv` were checked
against part-of-speech counts from all three splits, so the forms they decide are not held out: 17 gated rows
(islamists, followers, premises, lyrics, lighter, manners, poisoning, delighted, specifics, jeans, mistaken, annoyed,
lighting, goods, shocked, frightening, surprising) and one homograph (isolated). The generator therefore prints the
score with and without them. On 2026-09-23: accepted 398/409 = 97.31% and strict 386/409 = 94.38%; without those
forms, accepted 383/392 = 97.70% and strict 371/392 = 94.64%; traps 71/71. Later reviews of `overrides.tsv` use
part-of-speech counts from dev and test only.

## Format

UTF-8 with LF line endings, tab-separated, one header row, no quoting. Columns: `form`, `lemma` (UD's lemma, or for a
trap row the expected lookup result), `also` (alternatives joined by `|`, often empty), `kind` (`trap`, `noun`, `verb`,
`adj-adv`, `same`, `homograph`), `source`.
