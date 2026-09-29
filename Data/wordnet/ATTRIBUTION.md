# Attribution: WordNet 3.0 extract

`wordnet-extract.tsv` holds the part of **WordNet 3.0** that `tools/make-lexicon.py` reads, limited to the words of the
wordfreq 3.1.1 `large_en` list. WordNet 3.0 is by Princeton University (https://wordnet.princeton.edu/). The extract
comes from `WordNet-3.0.tar.gz`, the WordNet 3.0 release on the WordNet download page
(https://wordnet.princeton.edu/download/current-version): 11,537,239 bytes, sha256
`640db279c949a88f61f851dd54ebbb22d003f8b90b85267042ef85a3781d3a52`. The tarball itself is not committed.

`LICENSE` is the WordNet 3.0 license, copied unchanged from the tarball. It covers the extract and every file derived
from it, so the same text is in the lexicon's `LICENSE` and in `THIRD_PARTY_NOTICES.md`.

## Files read

From `WordNet-3.0/dict/` in the tarball:

- `data.noun`, `data.verb`, `data.adj`, `data.adv`: the words of each synset and how they are written (lowercase or
  capitalized), the synset offsets, and whether a synset has a usage-domain pointer (`;u`).
- `noun.exc`, `verb.exc`, `adj.exc`, `adv.exc`: irregular forms and their lemmas.

## Format

UTF-8 with LF line endings, tab-separated, one `#` header line, then one row per word, sorted.

| Column | Contents |
|---|---|
| `word` | A word of the wordfreq list that WordNet lists in any case, or that has an irregular-form entry or a spelling twin |
| `noun`, `verb`, `adj`, `adv` | How many synsets of that part of speech write the word in lowercase (adjective satellites count as `adj`) |
| `flags` | `c`: WordNet also writes the word capitalized (a name, place or brand sense). `u`: one of its synsets has a usage label (slang, vulgar, ethnic slur and so on) |
| `exceptions` | Irregular-form entries, comma-separated: `n:mouse` means `noun.exc` lists the word as a form of mouse; `v`, `a` and `r` stand for verb, adjective and adverb. Only lemmas in the wordfreq list are kept |
| `twins` | American spellings, joined by `\|`, that the generator's British-to-American patterns make from the word and that share a synset with it (colour: color) |

## Changes made

- Kept only single words that are in the wordfreq 3.1.1 `large_en` list (letters in Latin script, optionally joined by
  apostrophes). Multi-word and hyphenated entries are left out.
- Replaced synsets by per-part-of-speech counts and two flags; left out definitions, examples and relations. Synsets are
  used only to pair British and American spellings.
- Regenerate with `python3 tools/make-lexicon.py --extract-wordnet PATH/WordNet-3.0.tar.gz`, which checks the tarball's
  sha256 first.

## The Princeton name

The WordNet license forbids using the name of Princeton University or Princeton in advertising or publicity. Credit
WordNet in the notices, as the license requires, and keep Princeton's name out of App Store text and other marketing copy.
