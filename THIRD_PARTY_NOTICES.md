# Third-party notices

ReadStair's source code is licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). The app ships two
pieces of third-party material: its word list, `Packages/ReadStairCore/Sources/ReadStairCore/Resources/lexicon/`, which `tools/make-lexicon.py` derives from wordfreq, the New General Service List and
WordNet (the generator also writes this file), and its sample book, Chapter I of *Alice's Adventures in
Wonderland* as text in `App/ReadStair/SampleBook/alice.epub`, which is in the public domain. The word list is distributed
under the Creative Commons Attribution-ShareAlike 4.0 International License
(https://creativecommons.org/licenses/by-sa/4.0/legalcode), together with the WordNet 3.0 license.

The repository also holds test data that the app does not ship; its sources are credited below. Every directory of test
data has its own LICENSE and ATTRIBUTION.md.

## wordfreq

wordfreq 3.1.1, Copyright 2022 Robyn Speer (https://github.com/rspeer/wordfreq, DOI 10.5281/zenodo.7199437), `large_en` word list, licensed under CC BY-SA 4.0.

As wordfreq's license asks, ReadStair credits the sources wordfreq is built on:

- **SUBTLEX** word lists by Marc Brysbaert et al., http://crr.ugent.be/programs-data/subtitle-frequencies.
  SUBTLEX is freely available data. English lists used through wordfreq:
  - Brysbaert, M. & New, B. (2009). Moving beyond Kucera and Francis: A Critical Evaluation of Current Word
    Frequency Norms and the Introduction of a New and Improved Word Frequency Measure for American English.
    *Behavior Research Methods*, 41(4), 977-990.
  - van Heuven, W. J., Mandera, P., Keuleers, E., & Brysbaert, M. (2014). SUBTLEX-UK: A new and improved word
    frequency database for British English. *The Quarterly Journal of Experimental Psychology*, 67(6), 1176-1190.
- **Google Books Ngram Viewer**, http://books.google.com/ngrams (and Google Books Syntactic Ngrams).
- **OPUS OpenSubtitles 2018**, http://opus.nlpl.eu/OpenSubtitles.php, from the OpenSubtitles project,
  http://www.opensubtitles.org/.
- **The Leeds Internet Corpus**, University of Leeds Centre for Translation Studies, http://corpus.leeds.ac.uk/list.html.
- **Wikipedia**, http://www.wikipedia.org.
- **ParaCrawl**, https://paracrawl.eu.
- Word statistics collected from the Twitter streaming API (statistics only; no Twitter content is republished).

## New General Service List

New General Service List 1.2 by Browne, C., Culligan, B., and Phillips, J. (https://www.newgeneralservicelist.com/new-general-service-list), licensed under CC BY-SA 4.0.

## WordNet

WordNet 3.0, Princeton University (https://wordnet.princeton.edu/), under the WordNet 3.0 license:

```
WordNet Release 3.0

This software and database is being provided to you, the LICENSEE, by  
Princeton University under the following license.  By obtaining, using  
and/or copying this software and database, you agree that you have  
read, understood, and will comply with these terms and conditions.:  
  
Permission to use, copy, modify and distribute this software and  
database and its documentation for any purpose and without fee or  
royalty is hereby granted, provided that you agree to comply with  
the following copyright notice and statements, including the disclaimer,  
and that the same appear on ALL copies of the software, database and  
documentation, including modifications that you make for internal  
use or for distribution.  
  
WordNet 3.0 Copyright 2006 by Princeton University.  All rights reserved.  
  
THIS SOFTWARE AND DATABASE IS PROVIDED "AS IS" AND PRINCETON  
UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR  
IMPLIED.  BY WAY OF EXAMPLE, BUT NOT LIMITATION, PRINCETON  
UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES OF MERCHANT-  
ABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE  
OF THE LICENSED SOFTWARE, DATABASE OR DOCUMENTATION WILL NOT  
INFRINGE ANY THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR  
OTHER RIGHTS.  
  
The name of Princeton University or Princeton may not be used in  
advertising or publicity pertaining to distribution of the software  
and/or database.  Title to copyright in this software, database and  
any associated documentation shall at all times remain with  
Princeton University and LICENSEE agrees to preserve same.  
```

## Standard Ebooks (sample book and test pages)

The sample book, `App/ReadStair/SampleBook/alice.epub`, holds Chapter I of *Alice's Adventures in Wonderland* by
Lewis Carroll (1865), in the Standard Ebooks edition illustrated by John Tenniel
(https://github.com/standardebooks/lewis-carroll_alices-adventures-in-wonderland_john-tenniel); so do the test pages and
most test EPUBs in `Fixtures/` and the Alice sentences of `Data/eval/gloss-200.tsv`, and `Fixtures/alice-whole.epub`, for
tests only, holds Chapters I–XII. The text is in the public
domain, and Standard Ebooks dedicates its edition to the public domain under the CC0 1.0 Universal Public Domain
Dedication (https://creativecommons.org/publicdomain/zero/1.0/). The sample book's cover is the edition's: Ivan
Shishkin's painting *Amanita* (1879), in the public domain, under the edition's title box, whose lettering (League
Spartan, SIL Open Font License 1.1) is drawn into the image; no font is distributed. None of the edition's illustrations
is used. `tools/make-epub.sh` packages the chapters' unchanged XHTML, and the sample book's cover, into the sample book and
the test EPUBs. The app lays
the sample book out on the device in the system font; `tools/make-fixtures.swift` renders the test pages in
Source Serif 4 (SIL Open Font License 1.1; the font is not distributed). The ReadStair authors dedicate the EPUBs and the
rendered pages under CC0 1.0 too. `Fixtures/LICENSE` and `Fixtures/ATTRIBUTION.md` cover all of them.

## Test data, not shipped in the app

### Universal Dependencies English Web Treebank

`Data/ud-ewt/lemma-500.tsv` takes words and their lemmas, never sentences, from the Universal Dependencies English Web
Treebank (UD English-EWT) v2.18 (https://github.com/UniversalDependencies/UD_English-EWT). From its README: "Universal
Dependencies English Web Treebank annotations © 2013-2021 by The Board of Trustees of The Leland Stanford Junior
University. All Rights Reserved. The annotations and database rights of the Universal Dependencies English Web Treebank
are licensed under a Creative Commons Attribution-ShareAlike 4.0 International License." and "The underlying texts come
from various sources collected for the LDC English Web Treebank. Some parts are in the public domain.
Portions may be © 2012 Google Inc., © 2011 Yahoo! Inc., © 2012 Trustees of the University of Pennsylvania and/or © other
original authors." The file, including its rows written for ReadStair, is distributed under CC BY-SA 4.0
(https://creativecommons.org/licenses/by-sa/4.0/legalcode).
