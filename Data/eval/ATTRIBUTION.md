# Attribution — gloss evaluation set

`gloss-200.tsv` holds 200 words in context for grading the glosses ReadStair shows when a word is tapped: Apple
Translation of the headword and of its sentence, and Apple Intelligence's explanation of the word in that sentence.
The reference senses were written before any machine output was seen.

## Sources

- **173 rows** (`source` = `alice-chapter-1`) use sentences from Chapter I of *Alice's Adventures in Wonderland* by
  Lewis Carroll (1865), in the Standard Ebooks edition illustrated by John Tenniel. This is the repository fixture
  `Fixtures/source/alice-chapter-1.xhtml`; `Fixtures/ATTRIBUTION.md` records where it came from and its checksum.
  The text is in the public domain, and Standard Ebooks dedicates its edition to the public domain under the
  CC0 1.0 Universal Public Domain Dedication.
- **27 rows** (`source` = `original`) use sentences written for ReadStair where the chapter has no suitable example:
  A60, C05, C15–C20, D04, D05, E05–E15, F08, F10, G04, G14, G15 and H02. No other text was used.
- The headwords, reference senses and other senses in every row were written for ReadStair.

### Changes to the source text

- Markup removed (emphasis and bold included), along with the invisible word joiners (U+2060) around dashes.
  Spelling, punctuation and curly quotes are kept as in the source.
- The chapter is split into sentences with `NLTokenizer(unit: .sentence)`, the tokenizer the app uses, so each row's
  sentence is exactly what the word card would translate. That includes short pieces such as “Well!”, where the
  tokenizer splits at an exclamation mark.

## License

The whole file is dedicated to the public domain under CC0 1.0 Universal
(https://creativecommons.org/publicdomain/zero/1.0/). The Alice sentences are public domain as described above, and
the ReadStair authors dedicate the original sentences and all annotations under the same terms.

## Format

UTF-8 with LF line endings, tab-separated, one header row, no quoting (no field contains a tab or a line break).

| Column | Contents |
|---|---|
| `id` | Category letter and a two-digit number, A01 to H15 |
| `category` | A to H, see below |
| `sentence` | The sentence as the app would send it for translation |
| `word` | The tapped word, exactly as it appears in the sentence |
| `headword` | The dictionary form a learner would look up. It is lowercase with straight apostrophes, except for names. Hyphenated compounds stay whole (`rabbit-hole`). A possessive gives its owner (`Alice’s` → `Alice`), and a contraction is its own entry (`I'd`). A name gives the full name (`Zealand` → `New Zealand`) |
| `reference_sense` | The meaning in this sentence, as a short English definition |
| `other_senses` | Other real senses of the headword that are wrong here, separated by `; `. Empty when the headword has no other common sense |
| `source` | `alice-chapter-1` or `original` |

| Category | Items | What it checks |
|---|---|---|
| A | 60 | Common but unfamiliar words, all outside the 3,000 most frequent in the bundled band table: is the word gloss usable? |
| B | 40 | Polysemous words whose sense in the sentence matters: does the gloss of the word on its own mislead? |
| C | 20 | Archaic or literary senses common in older fiction (presently = soon, curious = strange, fancy = imagine) |
| D | 20 | Inflected and irregular forms (went, mice, lying, felt): are the headword and its gloss right? |
| E | 15 | Names and places, which should be kept or transliterated, not translated. E11–E15 (Will, Reading, Rose, Bath, Nice) are also ordinary words |
| F | 15 | Contractions, possessives and hyphenated compounds |
| G | 15 | Phrasal verbs. The word is the verb, and the reference sense names the whole phrasal verb first, e.g. “(make out) …” |
| H | 15 | High-frequency control words (bands 1–2), as a baseline |

When the word occurs more than once in its sentence, every occurrence has the reference sense. The one exception is
G09 (`going`), where the reference applies to “going out”.

## Grading

The reference senses are English definitions, so a bilingual grader can compare a gloss in any target language
against them. Each item gets three grades:

- **W**: the translation of the headword on its own, which the word card shows first. The card sends the headword the
  app derives from the page (the lemma, or a name as printed), which can differ from `headword` (`I've` gives `i`,
  `New Zealand` gives `Zealand`). W grades the translation of the app's headword; the experiments log both;
- **S**: how the word is rendered in the translation of the whole sentence;
- **M**: Apple Intelligence's explanation of the word in this sentence.

| Grade | Meaning |
|---|---|
| 2 | Matches `reference_sense`. For category E, keeping the name or transliterating it also scores 2 |
| 1 | A real sense of the word but not the one here (typically one of `other_senses`, which misleads in this sentence), or the right meaning put awkwardly |
| 0 | Wrong, empty, an error, or the English returned unchanged (outside category E) |
