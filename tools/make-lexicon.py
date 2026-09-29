#!/usr/bin/env python3
"""Build ReadStair's lexicon: a band for each of 25,000 lemmas, the word forms that read as another lemma, and the words of
the vocabulary test.

Every linguistic decision is made here, offline, and shipped as data. The app only looks words up (no suffix rules and no
NLTagger lemma), so a word gets the same lemma on every device, OS version and language-asset state. That matters because
the lemma is the key of the word's synced record.

A rebuild must also keep every lemma the committed tables give: a word's saved state and its iCloud record are keyed by its
lemma, so a form whose lemma changes would lose them. The gate compares the new tables with those on disk, for each form and
lemma there, and fails on any change not listed in the reviewed Data/lexicon/renames.tsv (form, old lemma, new lemma, reason).
Rows stay after the rebuild, as the record of every key that moved.

Usage, from the repository root:
  python3 tools/make-lexicon.py                        write Resources/lexicon/ and THIRD_PARTY_NOTICES.md
  python3 tools/make-lexicon.py --check                run this file's doctests, then rebuild into a temporary directory and
                                                       byte-compare (exit 1 on a difference); every gate runs, the lemma
                                                       one against the committed tables, so a changed lemma is named
  python3 tools/make-lexicon.py --extract-wordnet TGZ  rewrite Data/wordnet/wordnet-extract.tsv from WordNet-3.0.tar.gz, then stop
  python3 tools/make-lexicon.py --review DIR           also write lists for human review into DIR
  python3 tools/make-lexicon.py --review DIR --ud UD   also draw a draft evaluation set from UD English-EWT 2.18 (the .conllu
                                                       files in UD) into DIR, with its `also` column for the audit

Needs the pip package wordfreq==3.1.1 and no network. Third-party inputs are pinned by sha256 (PINNED). Nothing is written
when a gate fails (see gates()). Data/ud-ewt/lemma-500.tsv is the audited evaluation set: a draft never replaces it.
"""
import argparse
import bisect
import collections
import doctest
import hashlib
import importlib.metadata
import io
import math
import random
import re
import shutil
import sys
import tarfile
import tempfile
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEXICON = Path('Packages/ReadStairCore/Sources/ReadStairCore/Resources/lexicon')
NOTICES = Path('THIRD_PARTY_NOTICES.md')
NGSL = ROOT / 'Data/ngsl'
WORDNET = ROOT / 'Data/wordnet'
OVERRIDES = ROOT / 'Data/lexicon/overrides.tsv'
RENAMES = ROOT / 'Data/lexicon/renames.tsv'
EVAL_SET = ROOT / 'Data/ud-ewt/lemma-500.tsv'

WORDFREQ = '3.1.1'
PINNED = {
    'NGSL_12_stats.csv': '2098bab8955a120a9766c6282a51d7d578c6cb0a7d946600d2ffb73ba25a0b44',
    'NGSL_12_lemmatized_for_research.csv': 'd814f2a0a3c61479a2c5ad037661719a0cc6e7dbcde31f181b54f12d0f1e11a4',
    'WordNet-3.0.tar.gz': '640db279c949a88f61f851dd54ebbb22d003f8b90b85267042ef85a3781d3a52',
    'en_ewt-ud-train.conllu': 'd68e06122a702464c613076523d56740f047e5bbe89dd90ec32737e04d952143',
    'en_ewt-ud-dev.conllu': '39239e0a60db3ae68f4b7036189f11b6692741d10ff8240dd91f74f2760d90f8',
    'en_ewt-ud-test.conllu': 'fa024f43dc5da3c5ac02563bc9bd0e974f46cbb1560823976a8f342a37dc494a',
}

SIZE, WIDTH = 25_000, 1_000  # lemmas in bands.tsv, lemmas per band
MIN_ZIPF = 2.0               # rarer forms get no forms.tsv row, so they read as themselves
RATIO = 0.1                  # frequency a fold's base needs relative to the form, in the guarded cases of proposals()
T_BASE = 0.25                # a folded form whose own inflections reach this share of its frequency stays a word (setting)
DOM = 1.0                    # an -ing noun at least this frequent relative to the rest of its family stays a word (wedding)
PER_BAND, PSEUDO, SEED = 20, 100, 20260922
QUOTA = {'noun': 145, 'verb': 140, 'adj-adv': 21, 'same': 103, 'homograph': 20}  # UD rows of the evaluation set (adj-adv: all)

POS = ('noun', 'verb', 'adj', 'adv')
LETTER = dict(zip(POS, 'nvar'))  # WordNet's part-of-speech letters
WORD = re.compile(r"^[^\W\d_]+(?:'[^\W\d_]+)*$")  # letters, optionally joined by apostrophes (o'clock)
NOT_WORDS = set('ly ness ment ist sion ic ent ing'.split())  # word endings wordfreq counts as tokens (bit.ly, split words)
CJK_RANGES = ((0x1100, 0x11FF), (0x3000, 0x30FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xAC00, 0xD7AF), (0xF900, 0xFAFF), (0xFF00, 0xFFEF))
CJK = re.compile('[' + ''.join(f'{chr(a)}-{chr(b)}' for a, b in CJK_RANGES) + ']')  # the ranges tools/check-secrets.sh rejects
# Number words: books print most numbers as digits, so their frequency understates them; rank() puts them in band 1. Not a
# bare -ties, which would take parties and cities.
NUMBER = re.compile(r'^(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|'
                    r'eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion)'
                    r'(th|s)?$|^(first|second|third|fifth|eighth|ninth|twelfth|(twent|thirt|fort|fift|sixt|sevent|eight|ninet)(ies|ieth))$')
OFFENSIVE = re.compile(r'fanny|fuck|shit|cunt|dick|cock|piss|twat|slut|nigg|fag|whore|bitch|bastard|porn|dildo|boob|penis|'
                       r'vagina|anus|rape|cum|tits|titt|sex|nazi|coon|spic|kike|homo|pussy|masturb|orgasm|horny|suck|butt|'
                       r'semen|sodom|testic|genital|libid|ovulat|menstru|menopaus|impregnat|pa?edoph|thong|cleavag|fondl|orific|excret')

# What the app's lookup must give (a build gate), also the first rows of the lemma evaluation set: form -> the lemma, or for a
# contraction its parts ("i would|have": both readings are kept, alternatives joined by |).
TRAPS = [(w, w) for w in 'wed sheer hiss weed ass boss bus gas news species series broker buffer litter during always his us '
                         'james wound stove hinder willing pants'.split()] + [
    ('mice', 'mouse'), ('geese', 'goose'), ('flies', 'fly'), ('went', 'go'), ('children', 'child'), ('oxen', 'ox'), ('feet', 'foot'),
    ('teeth', 'tooth'), ('women', 'woman'), ('men', 'man'), ('was', 'be'), ('were', 'be'), ('been', 'be'), ('had', 'have'),
    ('lying', 'lie'), ('driven', 'drive'), ('sworn', 'swear'), ('withdrawn', 'withdraw'), ('travelled', 'travel'), ('stopped', 'stop'),
    ('bigger', 'big'), ('dined', 'dine'), ('stared', 'stare'), ('canes', 'cane'), ('robes', 'robe'), ('stockings', 'stocking'),
    ('colour', 'color'), ("can't", 'can not'), ("won't", 'will not'), ("i'd", 'i would|have'), ("don't", 'do not'),
    ("isn't", 'be not'), ("ain't", 'be not'), ("shan't", 'shall not'), ("i'm", 'i be'), ("you're", 'you be'),
    ("they've", 'they have'), ("we'll", 'we will'), ("it's", 'it be|have'), ("let's", 'let us'), ('cannot', 'can not'),
    ("alice's", 'alice'), ("children's", 'child'), ("o'clock", "o'clock"), ('rabbit-holes', 'rabbit-hole'),
    ("rabbit-hole's", 'rabbit-hole'), ('well-known', 'well-known')]


# --- Inputs

def sha256(data):
    return hashlib.sha256(data).hexdigest()


def pinned(path):
    data = Path(path).read_bytes()
    if sha256(data) != PINNED[Path(path).name]:
        sys.exit(f'{path}: sha256 differs from the pinned {PINNED[Path(path).name]}')
    return data


def rows(path):
    """The tab-separated fields of each line of a UTF-8 file, skipping `#` lines."""
    return [line.split('\t') for line in Path(path).read_text(encoding='utf-8').splitlines() if line and not line.startswith('#')]


def wordfreq_forms():
    """wordfreq's large English list as {form: frequency}, most frequent first, and the part of it that is Latin-script words.
    Leaving out NOT_WORDS also lets the app join a word broken at the end of a line before such an ending (earnest-ly)."""
    if importlib.metadata.version('wordfreq') != WORDFREQ:
        sys.exit(f'Needs wordfreq {WORDFREQ} (found {importlib.metadata.version("wordfreq")}); other versions give other output')
    from wordfreq import get_frequency_dict
    every = get_frequency_dict('en', 'large')
    latin = lambda w: all(unicodedata.name(c, '').startswith('LATIN ') for c in w if c.isalpha())
    return every, {w: f for w, f in every.items() if WORD.match(w) and latin(w) and w not in NOT_WORDS}


# British -> American spelling patterns; --extract-wordnet keeps a pair only when both spellings share a WordNet synset. Not
# ss/s, que/ck, ph/f or fil/fill, whose pairs a reader would take for another word (canvass -> canvas, cheque -> check).
SPELLINGS = [('our', 'or'), ('ise', 'ize'), ('isation', 'ization'), ('yse', 'yze'), ('tre', 'ter'), ('bre', 'ber'), ('ence', 'ense'),
             ('ogue', 'og'), ('sceptic', 'skeptic'), ('practis', 'practic'), ('licenc', 'licens'), ('mme', 'm'), ('ae', 'e'), ('oe', 'e'),
             ('ller', 'ler'), ('llor', 'lor'), ('llery', 'lry'), ('llous', 'lous'), ('llist', 'list'), ('illi', 'ili'), ('lment', 'llment'),
             ('lful', 'llful'), ('fulfil', 'fulfill'), ('enrol', 'enroll'), ('instal', 'install'), ('ement', 'ment'), ('ium', 'um'),
             ('mould', 'mold'), ('moult', 'molt'), ('plough', 'plow'), ('sulph', 'sulf'), ('osy', 'ozy'), ('moustache', 'mustache'),
             ('artefact', 'artifact'), ('grey', 'gray'), ('focuss', 'focus'), ('isable', 'izable'), ('oeuvre', 'euver')]


def extract_wordnet(tarball, F):
    """What the build reads from WordNet 3.0, for the words of F: sense counts, flags, exceptions and spelling twins."""
    tar = tarfile.open(fileobj=io.BytesIO(pinned(tarball)))
    lines = lambda name: tar.extractfile(f'WordNet-3.0/dict/{name}').read().decode('latin-1').splitlines()
    senses = collections.defaultdict(lambda: [0, 0, 0, 0])
    capital, usage, synsets, exceptions = set(), set(), collections.defaultdict(set), collections.defaultdict(list)
    for i, pos in enumerate(POS):
        for line in lines(f'data.{pos}'):
            if line.startswith(' '):
                continue  # the license header
            head = line.split('|')[0].split()
            for word in (re.sub(r'\(.*\)$', '', w) for w in head[4:4 + 2 * int(head[3], 16):2]):  # without markers such as (a)
                low = word.lower()
                if word == low:
                    senses[low][i] += 1
                    synsets[low].add(LETTER[pos] + head[0])
                else:
                    capital.add(low)
                if ' ;u ' in line:
                    usage.add(low)  # the synset has a usage label: slang, vulgar, ethnic slur ...
        for line in lines(f'{pos}.exc'):
            form, *targets = line.split()
            exceptions[form] += [f'{LETTER[pos]}:{t}' for t in targets if t in F and t != form]
    out = []
    for word in F:
        twins = []
        for gb, us in SPELLINGS:
            i = word.find(gb)
            while i >= 0:
                twin = word[:i] + us + word[i + len(gb):]
                if twin in F and twin not in twins and synsets.get(word, set()) & synsets.get(twin, set()):
                    twins.append(twin)
                i = word.find(gb, i + 1)
        if word in senses or word in capital or exceptions.get(word) or twins:
            flags = ('c' if word in capital else '') + ('u' if word in usage else '')
            out.append('\t'.join([word, *map(str, senses.get(word, [0] * 4)), flags, ','.join(exceptions.get(word, [])), '|'.join(twins)]))
    header = ('# WordNet 3.0 extract for tools/make-lexicon.py (see ATTRIBUTION.md): '
              'word<TAB>noun<TAB>verb<TAB>adj<TAB>adv<TAB>flags<TAB>exceptions<TAB>twins')
    return ('\n'.join([header] + sorted(out)) + '\n').encode('utf-8')


class WordNet:
    """The committed WordNet extract. pos[p]: words with a lowercase sense of part of speech p; senses[w][p]: their count;
    capital: words also written capitalized; cap_only: words written only capitalized (james, wales); usage: words of a synset
    with a usage label; exc[p]: irregular form -> lemmas; twins: British spelling -> American spellings sharing a synset."""

    def __init__(self, path):
        self.pos = {p: set() for p in POS}
        self.exc = {p: {} for p in POS}
        self.senses, self.capital, self.usage, self.twins = {}, set(), set(), {}
        for word, *counts, flags, exceptions, twins in rows(path):
            self.senses[word] = dict(zip(POS, map(int, counts)))
            for p in POS:
                if self.senses[word][p]:
                    self.pos[p].add(word)
            if 'c' in flags:
                self.capital.add(word)
            if 'u' in flags:
                self.usage.add(word)
            for item in filter(None, exceptions.split(',')):
                p, target = item.split(':')
                self.exc[next(q for q in POS if LETTER[q] == p)].setdefault(word, []).append(target)
            if twins:
                self.twins[word] = twins.split('|')
        self.any = set().union(*self.pos.values())
        self.cap_only = self.capital - self.any


def load_ngsl():
    """NGSL 1.2: each headword's U (frequency per million) and rank, and form -> the headwords whose families list it."""
    stats = [line.split(',') for line in pinned(NGSL / 'NGSL_12_stats.csv').decode('ascii').splitlines()[1:]]
    U = {lemma.lower(): float(u) for lemma, _, _, u in stats}
    rank = {lemma.lower(): int(r) for lemma, r, _, _ in stats}
    family = collections.defaultdict(list)
    for line in pinned(NGSL / 'NGSL_12_lemmatized_for_research.csv').decode('ascii').splitlines():
        if line.strip() and not line.startswith('##'):
            head, *forms = line.lower().split(',')
            for form in forms:
                if form != head and head not in family[form]:
                    family[form].append(head)
    return U, rank, family


def load_overrides():
    """Reviewed decisions: form -> None (keep: the form is its own lemma) or the lemma it folds into."""
    out = {}
    for fields in rows(OVERRIDES):
        if len(fields) != 3 or not fields[2] or not (fields[1] == 'keep' or fields[1].startswith('fold:')):
            sys.exit(f'{OVERRIDES}: bad row {fields}; want form<TAB>keep|fold:<lemma><TAB>reason')
        out[fields[0]] = None if fields[1] == 'keep' else fields[1][5:]
    return out


def load_renames():
    """Reviewed lemma changes: the set of (form, old lemma, new lemma) a rebuild may make."""
    out = set()
    for fields in rows(RENAMES):
        if len(fields) != 4 or not all(fields) or fields[1] == fields[2]:
            sys.exit(f'{RENAMES}: bad row {fields}; want form<TAB>old<TAB>new<TAB>reason, with old and new different')
        out.add(tuple(fields[:3]))
    return out


def committed():
    """The lookup of the tables on disk, before a rebuild replaces them; empty when there are none. Only its lemmas are used."""
    paths = [ROOT / LEXICON / name for name in ('bands.tsv', 'forms.tsv')]
    return Lookup(*(dict(rows(p)) if p.exists() else {} for p in paths))


# --- Lemmas

RULES = {'noun': [('s', ''), ('ses', 's'), ('xes', 'x'), ('zes', 'z'), ('ches', 'ch'), ('shes', 'sh'), ('men', 'man'), ('ies', 'y')],
         'verb': [('s', ''), ('ies', 'y'), ('es', 'e'), ('es', ''), ('ed', 'e'), ('ed', ''), ('ing', 'e'), ('ing', '')],
         'adj': [('er', ''), ('est', ''), ('er', 'e'), ('est', 'e')]}  # WordNet's suffix rules
CLOSED = set('be have do will would can could shall should may might must a an i it he us in out up on off by as at not no so all '
             'of to for with from and or but if'.split())
PARADIGM = {'be': set('am is are was were been being'.split()), 'have': set('has had having'.split()),
            'do': set('does did done doing'.split())}  # not it: the possessive its is its own word, like his and their
VOWELS = set('aeiou')


def short_cvc(base):
    """One syllable ending consonant-vowel-consonant (din, star): dined and stared come from dine and stare, not din and star."""
    groups = re.findall(r'[aeiouy]+', base[1:]) + re.findall(r'^[aeiou]+', base)
    return len(base) >= 3 and len(groups) == 1 and base[-1] not in VOWELS | set('wxy') and base[-2] in VOWELS and base[-3] not in VOWELS


def lemmatize(F, wn, U, family, overrides):
    """The lemma of every form in F without an apostrophe, and counts of the decisions made after the first pass."""

    def known(word, pos):  # WordNet writes words without accents (cafe): cafés is the plural of café
        return (word if word.isascii() else unicodedata.normalize('NFD', word).encode('ascii', 'ignore').decode()) in wn.pos[pos]

    def proposals(form, guarded):
        """Candidate lemmas as (lemma, kind), kind 'exc' (a WordNet exception) or 'rule' (a suffix rule). Unguarded: every
        exception target and suffix-rule base, for NGSL to choose from. Guarded: only the safe ones."""
        out = []
        # A noun or verb of its own, or a name: a participle that WordNet lists only as an adjective (verified, woven) is not
        wordnet_word = form in wn.pos['noun'] or form in wn.pos['verb'] or form in wn.cap_only
        for pos in POS:
            # A form WordNet has only capitalized (james) folds only into a base at least as frequent, and a lowercase noun
            # ending in -s (pants) folds by a verb rule only into a base at least RATIO as frequent.
            strict = 1.0 if form in wn.cap_only else RATIO if pos == 'verb' and form in wn.pos['noun'] and form.endswith('s') else 0
            for t in wn.exc[pos].get(form, []):
                # An exception needs a base at least as frequent when the form is a word itself (stove is not stave, hinder
                # not hind, but felt is feel); adjective and adverb exceptions never apply to nouns.
                need = 1.0 if wordnet_word else RATIO
                if t in F and (not guarded or (F[t] >= need * F[form] and not (pos in ('adj', 'adv') and form in wn.pos['noun']))):
                    out.append((t, 'exc'))
            if guarded and (known(form, pos) or (pos == 'adj' and known(form, 'noun'))):
                continue  # no suffix rule of a part of speech the form has itself (news, sheer), no adjective rule on a noun
            for suffix, repl in RULES.get(pos, []):
                if not form.endswith(suffix) or len(form) <= len(suffix) + 1:
                    continue
                base = form[:-len(suffix)] + repl
                if not guarded:
                    out.append((base, 'rule'))
                    continue
                if (suffix == 's' and form.endswith('ss')) or len(base) < 3 \
                        or (suffix == 'es' and repl == '' and not re.search(r'(s|x|z|ch|sh|o)es$', form)):
                    continue  # boss; canes and robes (-es -> '' only after a sibilant or o)
                bare = repl == '' and suffix in ('ed', 'ing', 'er', 'est')
                bases = [base] if known(base, pos) and base in F and not (bare and short_cvc(base)) else []
                if bare and len(base) >= 4 and base[-1] == base[-2] and base[-1] in 'bdgklmnprtvz' \
                        and base[:-1] in wn.pos[pos] and base[:-1] in F:
                    bases.append(base[:-1])  # stopped -> stop
                out += [(b, 'rule') for b in bases if F[b] >= strict * F[form]]
        seen = {form}
        return [(c, k) for c, k in out if not (c in seen or seen.add(c))]

    def decide(form):
        raw = proposals(form, guarded=False)
        if form in U:  # an NGSL headword reads as the most frequent headword among itself and its families (found -> find)
            best = max([form] + [c for c, _ in raw if c in family.get(form, [])], key=lambda h: (U[h], h))
            return best, 'self' if best == form else 'ngsl'
        confirmed = [(c, k) for c, k in raw if c in family.get(form, [])]
        if confirmed:  # a member of NGSL families folds into the most frequent of their headwords the rules reach (saw -> see)
            return max(confirmed, key=lambda ck: (U[ck[0]], ck[0]))
        guarded = proposals(form, guarded=True)
        return max(guarded, key=lambda ck: (F[ck[0]], ck[0])) if guarded else (form, 'self')

    decision = {form: decide(form) for form in F if "'" not in form}
    counts = collections.Counter()

    # A folded form whose own inflections reach T_BASE of its frequency is a word in its own right (wound, setting), and so
    # is an -ing noun that dominates the rest of its family (wedding, training).
    mass, family_freq = collections.Counter(), collections.Counter()
    for g, (t, kind) in decision.items():
        family_freq[t] += F[g]
        if kind == 'rule':
            mass[t] += F[g]
    for f, (t, kind) in list(decision.items()):
        if t != f and (mass[f] >= T_BASE * F[f] or (f.endswith('ing') and f in wn.pos['noun'] and F[f] >= DOM * (family_freq[t] - F[f]))):
            decision[f] = (f, 'self')
            counts['base words'] += 1

    # British spelling: a form that stays itself folds into its American twin (colour -> color) unless the twin is under half as
    # frequent, so near-equal pairs join (grey -> gray, theatre -> theater) while dialogue and glamour keep their spelling.
    for form, (lemma, _) in list(decision.items()):
        twins = [t for t in wn.twins.get(form, []) if F[t] * 2 > F[form]]
        if twins and lemma == form:
            decision[form] = (max(twins, key=F.get), 'spell')
            counts['spelling folds'] += 1

    def reading(form):
        """Follow suffix-rule and spelling folds (colours -> colour -> color), but not past an irregular one: thoughts reads as
        thought, while thought itself reads as think."""
        lemma, kind = decision.get(form, (form, 'self'))
        for _ in range(5):
            following, next_kind = decision.get(lemma, (lemma, 'self'))
            if kind not in ('rule', 'spell') or next_kind not in ('rule', 'spell'):
                break
            lemma, kind = following, next_kind
        return lemma

    # Only a word's own paradigm folds into a function word: willing, cans, beings and outing stay themselves.
    for form in list(decision):
        r = reading(form)
        if r != form and r in CLOSED and form not in PARADIGM.get(r, ()):
            decision[form] = (form, 'self')
            counts['closed-class blocks'] += 1

    for form, lemma in overrides.items():
        if form not in decision:
            sys.exit(f'{OVERRIDES}: {form} is not a wordfreq word without an apostrophe')
        decision[form] = (lemma or form, 'exc')

    # The -ings plural of an -ing noun is a noun of its own when it would read as a verb: sayings is never say, earnings never
    # earn. One that reads as an -ing word follows it (meetings -> meeting, things -> thing).
    for form in list(decision):
        r = reading(form)
        if form.endswith('ings') and form not in overrides and r != form and not r.endswith('ing') and known(form[:-1], 'noun'):
            decision[form] = (form, 'self')
            counts['-ings nouns'] += 1
    return {form: reading(form) for form in decision}, counts


# --- Ranking and the form table

CLITIC = {"n't": 'not', "'ll": 'will', "'re": 'be', "'ve": 'have', "'m": 'be', "'d": 'would|have', "'s": 'be|have'}
NT_HOST = {'ca': 'can', 'wo': 'will', 'sha': 'shall', 'ai': 'be'}
PRONOUN = set('i you he she it we they that there here who what where when why how this'.split())
HOSTS = {"n't": set('do does did is are was were has have had can could will would shall should may might must need dare ought '
                    'ca wo sha ai'.split()),
         "'ve": PRONOUN | set('could would should might must may will'.split()), "'d": PRONOUN, "'ll": PRONOUN, "'re": PRONOUN,
         "'m": {'i'}, "'s": PRONOUN - {'i', 'you', 'we', 'they', 'this'}}
CONTRACTION = re.compile(r"^(.+?)(n't|'ll|'re|'ve|'m|'d|'s)$")
WHOLE = {"let's": 'let us', 'cannot': 'can not', "ma'am": 'madam', "o'er": 'over', "ne'er": 'never', "e'er": 'ever',
         "y'all": 'you all'}  # rows kept at any frequency: wordfreq splits ma'am and o'er in two, so they are not in F


def rank(F, lemma_of):
    """Credit each form's frequency to the lemma the app reads it as. Returns {lemma: band} for the SIZE most frequent lemmas
    in rank order, the credited frequencies, and the contraction rows."""
    reading = lambda w: lemma_of.get(w, w)
    credit, contractions = collections.Counter(), {}
    for form, f in F.items():
        m = CONTRACTION.match(form)
        if form in WHOLE:
            credit[reading(WHOLE[form].split()[0])] += f
        elif m and m[1] in HOSTS[m[2]]:  # can't -> can not, it's -> it be|have
            host = reading(NT_HOST.get(m[1], m[1]) if m[2] == "n't" else m[1])
            contractions[form] = f'{host} {CLITIC[m[2]]}'
            credit[host] += f
        elif form.endswith("'s") and len(form) > 2:
            credit[reading(form[:-2])] += f  # a possessive: the app strips 's
        else:
            credit[reading(form)] += f
    ranked = sorted(credit.items(), key=lambda kv: (not NUMBER.match(kv[0]), -kv[1], kv[0]))[:SIZE]  # number words first
    return {w: i // WIDTH + 1 for i, (w, _) in enumerate(ranked)}, credit, contractions


def form_rows(F, lemma_of, bands, contractions):
    """form -> lemma parts: forms of at least MIN_ZIPF that read as a lemma in the table, or as a lemma beyond it that is itself
    that frequent (waistcoats -> waistcoat keeps rare words' keys stable); contractions; WHOLE rows."""
    floor = 10 ** (MIN_ZIPF - 9)
    out = {}
    for form, lemma in lemma_of.items():
        if lemma != form and F[form] >= floor and (lemma in bands or (F.get(lemma, 0) >= floor and lemma_of.get(lemma, lemma) == lemma)):
            out[form] = lemma
    for form, parts in contractions.items():
        if F[form] >= floor and all(p.split('|')[0] in bands for p in parts.split()):
            out[form] = parts
    return dict(sorted({**out, **WHOLE}.items()))


class Lookup:
    """The app's lookup (ReadStairCore's Lexicon), mirrored for the gates: forms.tsv first, then a possessive 's, then a
    hyphenated compound, whose last piece alone is reduced from a plural (rabbit-holes -> rabbit-hole)."""

    def __init__(self, bands, forms):
        self.bands, self.forms = bands, forms

    def parts(self, key):
        if key in self.forms:
            return self.forms[key].split(' ')
        return self.parts(key[:-2]) if key.endswith("'s") and len(key) > 2 else [key]

    def lemma(self, key):
        parts = self.parts(key)
        if len(parts) > 1:
            return key  # a contraction is its own lemma (won't)
        if '-' not in parts[0]:
            return parts[0]
        *pieces, last = [p for p in parts[0].split('-') if p]
        base = self.lemma(last)
        return '-'.join(pieces + [base if last in (base + 's', base + 'es') else last])

    def band(self, lemma):
        if lemma in self.bands:
            return self.bands[lemma]
        pieces = [self.lemma(p) for p in lemma.split('-') if p] if '-' in lemma else self.parts(lemma)
        if len(pieces) < 2:
            return None
        found = [[self.bands[a] for a in piece.split('|') if a in self.bands] for piece in pieces]
        return None if not all(found) else max(min(b) for b in found)

    def predicted(self, form):
        """What the evaluation set compares with its lemma column."""
        return self.lemma(form) if '-' in form else ' '.join(self.parts(form))


# --- Vocabulary test

FUNCTION = set('be have do will would can could shall should may might must a an the and or but if of to for with from in out up on off '
               'by as at not no so all through about above across after against along among around before behind below beneath '
               'beside between beyond down during except inside into near since till toward towards under until upon within without '
               'also very just even still ever never quite rather such than then there here these those this that though although '
               'unless whether while other another whatever each every either both many much some any few several'.split())
PREFIX = re.compile(r'^(un|re|dis|mis|pre|over|under|out|non|sub|super|inter|anti|de|co|en|in|im|ir|il)(?=...)')
SUFFIX = re.compile(r'(?<=...)(able|ible|ness|less|ful|ly|ment|er|ist|ism|ish|ship|hood|ity|ize|ise|ation|ion|al|ic|y|ous|ive|ant|ent|'
                    r's|ed|ing|ings)$')
# Pseudowords reviewed by hand. An approved one stays while it passes every rule of vocabulary(), so a change to the lexicon
# does not replace it; a rejected one is never used. The seeded draw fills the rest of the length quotas. REJECTED also lists
# real words a learner would know as a name or brand (gemma, gosling, corolla), from another language (hombre, en masse) or
# from a clipped form (takin'); the real-word draw skips them.
APPROVED = set('achatome affiestic agnigor ancoge antourna antrulate aphow arfert aspow atirt babbigh bannump blelvism '
               'carchendier chissiar cislarnon cloopic clurge cogrop consaff decoudia delendrangle desaunse diabbia dispinoosh '
               'drorry duastreth eppor estrephount etount evemp evirtenge exciol extip flelophity glism grutor guirm halvalme '
               'immiano ingib intibluate itimp juroct keassor kentamp liold metamp metennan mospo mossor mothaut naissel nionch '
               'nutraurt obsim obsor occit ombion oppit peccinism phausiocal pindrel pisteft plorm praclari psyna reettli '
               'restrondrery rifia rincort scerby shaccol shunhace sisige skenenglate spatoug stielinder streleccate stuaspar '
               'suilar sulsiffe sumigh systoon thandemird thecaide trelmonal tromicida tupplia uluct uningort urrew valoonvate '
               'veack vicub vocath wharcular whivadend whovidle widorn wreff zerey zerfe'.split())
REJECTED = set('educeitond umpeell judicoosm tongli ictoode cindriliart ansulapre emoup feamp elovatuar diregrog reeddeat '
               'casculull dilitrer lurchit cemiateray ombitiott irsontre embioll stroincirche citaistren anklay blooff '
               'moisturchia centretensty dielmestic empoothey mastreriatch immut yeaff blicinistry exceff nituan survinstord '
               'solinglairy truirry whootch moistaimple reendreal dristiory heristranste grallock gelip plebbit vedicank '
               'diesouster arlake weaff viabi priorchinct teingato gualoga femeaniest fennole allergootch ephor oxiste slashicap '
               'marcel gemma marguerite marge lotte bobby sonny tribune corolla angelica gosling gawker columbine fitch mulligan '
               'monte hombre takin masse'.split())


def vocabulary(bands, forms, wn, ngsl_rank, every):
    """PER_BAND real words for each band, spaced evenly by rank through the eligible lemmas, and PSEUDO pseudowords: the
    APPROVED ones, then new ones made by swapping letter groups of easy real words (Wuggy-style). Returns the rows, each
    pseudoword's trigram score and statistics of the draw."""
    real = {w for w in bands if len(w) >= 3}
    easy = real | {f for f, v in forms.items() if ' ' not in v and len(f) >= 3}  # and their forms (organized, working)

    def transparent(w):
        """An easy word plus an affix or ending (misstep, unorganized, relaxed, heavens), two table words (sinkhole), two easy
        words of 4+ letters (hardworking; with 3 letters, curate would be cur + ate) or one plus up or by (lookup, standby)."""
        stem = SUFFIX.sub('', w)
        return PREFIX.sub('', w) != w and PREFIX.sub('', w) in easy or stem != w and (stem in easy or stem + 'e' in easy) \
            or any(w[:i] in real and w[i:] in real for i in range(3, len(w) - 2)) \
            or any(w[:i] in easy and w[i:] in easy for i in range(4, len(w) - 3)) \
            or w[-2:] in ('up', 'by') and len(w) >= 6 and w[:-2] in easy

    ngsl_band = {w: (r - 1) // 1000 + 1 for w, r in ngsl_rank.items()}
    pool = collections.defaultdict(list)
    for lemma, band in bands.items():  # rank order
        senses = wn.senses.get(lemma, {})
        if re.fullmatch(r'[a-z]{5,12}', lemma) and (senses.get('noun') or senses.get('verb') or senses.get('adj')) \
                and lemma not in wn.capital and lemma not in FUNCTION and lemma not in wn.usage and not OFFENSIVE.search(lemma) \
                and lemma not in forms and not NUMBER.match(lemma) and lemma not in REJECTED and sum(senses.values()) <= 12 \
                and (ngsl_band.get(lemma) == band if band <= 3 else lemma not in ngsl_band and not transparent(lemma)):
            pool[band].append(lemma)
    sample = {b: [pool[b][i * len(pool[b]) // PER_BAND] for i in range(min(PER_BAND, len(pool[b])))] for b in range(1, SIZE // WIDTH + 1)}

    # Letter groups (consonant or vowel runs) by slot: initial, medial or final.
    segments = lambda w: re.findall(r'[aeiouy]+|[^aeiouy]+', w)
    slot = lambda i, s: ('V' if s[i][0] in 'aeiouy' else 'C') + ('0' if i == 0 else '$' if i == len(s) - 1 else '')
    lex = [w for w in bands if re.fullmatch(r'[a-z]{3,}', w)]
    groups = collections.defaultdict(collections.Counter)
    for w in lex:
        s = segments(w)
        for i in range(len(s)):
            groups[slot(i, s)][s[i]] += 1
    choices = {k: sorted(g for g, n in c.items() if n >= (150 if k[0] == 'V' else 40)) for k, c in groups.items()}

    # A letter-trigram model of the 20,000 most frequent lemmas; the lemmas ranked below them are the held-out real words.
    trigrams, contexts = collections.Counter(), collections.Counter()
    for w in lex:
        if bands[w] <= 20:
            t = f'^{w}$'
            for i in range(len(t) - 2):
                trigrams[t[i:i + 3]] += 1
                contexts[t[i:i + 2]] += 1

    def score(w):  # mean log-probability per letter, add-one smoothed over 26 letters and the end mark
        t = f'^{w}$'
        return sum(math.log((trigrams[t[i:i + 3]] + 1) / (contexts[t[i:i + 2]] + 27)) for i in range(len(w))) / len(w)

    held_out = sorted(score(w) for w in lex if bands[w] > 20)
    floor = held_out[len(held_out) // 4]  # the 25th percentile

    top = [w for w in every if re.fullmatch(r'[a-z]+', w)][:100_000]  # in wordfreq order, most frequent first
    near1 = set(top) | {w[:i] + w[i + 1:] for w in top for i in range(len(w))}  # symmetric deletes: edit distance <= 1

    def deletes2(w):
        one = {w[:i] + w[i + 1:] for i in range(len(w))}
        return {w} | one | {x[:i] + x[i + 1:] for x in one for i in range(len(x))}

    near2 = set().union(*(deletes2(w) for w in top[:20_000] if len(w) >= 5))  # within 2 edits of a top-20k word of 5+ letters

    # Length quotas match the real words of bands 1-12, rounded by largest remainder so they add up to PSEUDO.
    lengths = collections.Counter(len(w) for b in range(1, 13) for w in sample[b])
    exact = {n: PSEUDO * c / sum(lengths.values()) for n, c in lengths.items()}
    quota = {n: int(x) for n, x in exact.items()}
    for n in sorted(exact, key=lambda n: (int(exact[n]) - exact[n], n))[:PSEUDO - sum(quota.values())]:
        quota[n] += 1
    quota = collections.Counter(quota)

    def flaw(c):  # the first rule a pseudoword breaks, or ''
        t = f'^{c}$'
        return ('a real word' if c in every else
                'inflection-shaped' if re.search(r'(s|ed|ing|ly)$', c) else
                'rare trigram' if any(trigrams[t[j:j + 3]] < 5 for j in range(len(t) - 2)) else
                'less word-like than held-out real words' if score(c) < floor else
                'offensive fragment' if OFFENSIVE.search(c) else
                'affix or compound of real words' if transparent(c) else
                'near a real word' if c in near1 or any(c[:i] + c[i + 1:] in near1 for i in range(len(c)))
                or (len(c) >= 7 and not deletes2(c).isdisjoint(near2)) else
                'rejected on review' if c in REJECTED else '')

    pseudo, rejected = [], collections.Counter()
    for c in sorted(APPROVED):
        reason = 'length quota full' if quota[len(c)] <= 0 else flaw(c)
        if reason:
            rejected[f'approved on review, now {reason}'] += 1
        else:
            pseudo.append(c)
            quota[len(c)] -= 1
    templates = sorted(w for b in range(1, 11) for w in pool[b] if len(w) <= 8)
    rng, tries = random.Random(SEED), 0
    while sum(quota.values()) and tries < 2_000_000:  # the long lengths are slow to fill
        tries += 1
        w = rng.choice(templates)
        s = segments(w)
        for i in rng.sample(range(len(s)), 1 if len(w) <= 5 else min(2, len(s))):
            s[i] = rng.choice(choices[slot(i, s)])
        c = ''.join(s)
        reason = 'length quota full or unchanged' if c == w or quota[len(c)] <= 0 else flaw(c) or ('duplicate' if c in pseudo else '')
        if reason:
            rejected[reason] += 1
        else:
            pseudo.append(c)
            quota[len(c)] -= 1
    stats = {'pool': {b: len(pool[b]) for b in sorted(pool)}, 'tries': tries, 'rejected': dict(rejected), 'floor': floor,
             'held_out_quartiles': [held_out[len(held_out) * q // 4] for q in (1, 2, 3)]}
    out = [(w, b) for b in sample for w in sample[b]] + [(p, 0) for p in sorted(pseudo)]
    return out, {p: score(p) for p in pseudo}, stats


# --- Evaluation set (UD English-EWT), words only

OPEN = {'NOUN', 'VERB', 'ADJ', 'ADV', 'AUX'}


def ud_tokens(path):
    """(form, lemma, UPOS, sentence) of the open-class, alphabetic, non-typo single words of a .conllu file, lowercased."""
    text, skip = '', set()
    for line in pinned(path).decode('utf-8').splitlines():
        if not line:
            skip = set()
        elif line.startswith('# text = '):
            text = line[9:]
        elif not line.startswith('#'):
            c = line.split('\t')
            if '-' in c[0]:
                first, last = map(int, c[0].split('-'))
                skip = set(range(first, last + 1))  # the pieces of a multiword token (wo + n't)
            elif '.' not in c[0] and int(c[0]) not in skip and c[3] in OPEN and not re.search(r'Typo=Yes|Abbr=Yes|Style=', c[5]) \
                    and 'CorrectForm=' not in c[9] and re.fullmatch(r'[A-Za-z]+', c[1]) and re.fullmatch(r'[A-Za-z]+', c[2]):
                yield c[1].lower(), c[2].lower(), c[3], text


def eval_set(ud, every, wn, family):
    """A draft of the evaluation set: TRAPS plus UD rows drawn from the train split only, from forms that never occur in dev or
    test (those were used to set the constants). `also` lists other lemmas a reader could accept, derived from WordNet and NGSL
    without the lexicon; EVAL_SET holds the hand-audited values. Returns the rows and one train sentence for each UD row."""
    held_out = {f for split in ('dev', 'test') for f, *_ in ud_tokens(ud / f'en_ewt-ud-{split}.conllu')}
    gold, upos, context = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter), {}
    for f, g, pos, text in ud_tokens(ud / 'en_ewt-ud-train.conllu'):
        gold[f][g] += 1
        upos[f][pos] += 1
        context.setdefault((f, g), text)
    top, traps, verbs = set(list(every)[:80_000]), dict(TRAPS), wn.pos['verb']

    def also(f, g):
        accepted = set(family.get(f, []) + family.get(g, []))  # an NGSL headword
        accepted.update(t for t in wn.twins.get(g, []) if t in top)  # an American spelling
        if f == g and re.search(r'(ed|ing|en)$', f):  # a verb for a participle UD keeps (-ed, -ing, -en)
            accepted.update(t for t in wn.exc['verb'].get(f, []) if t in verbs)
            for suffix, repl in (('ing', ''), ('ing', 'e'), ('ed', ''), ('ed', 'e'), ('ied', 'y')):
                base = f[:-len(suffix)] + repl
                if f.endswith(suffix) and base in verbs:
                    accepted.add(base)
                if f.endswith(suffix) and repl == '' and len(base) > 3 and base[-1] == base[-2] and base[:-1] in verbs:
                    accepted.add(base[:-1])
        accepted.discard(g)
        return '|'.join(sorted(accepted))

    frames = collections.defaultdict(list)
    for f, lemmas in gold.items():
        n = sum(lemmas.values())
        if f in traps or f in held_out or n < 2 or f not in top or re.search(r'(.)\1\1', f) or OFFENSIVE.search(f):
            continue
        g, k = lemmas.most_common(1)[0]
        others = sorted(x for x, c in lemmas.items() if c / n >= 0.1 and x != g)
        if k / n < 0.9 and others:  # a homograph: tracked, not gated
            frames['homograph'].append((f, g, '|'.join(others)))
        elif len(lemmas) == 1 and (f != g or re.search(r'(s|ed|ing|er|est|en)$', f)):
            kind = 'same' if f == g else {'NOUN': 'noun', 'VERB': 'verb', 'AUX': 'verb'}.get(upos[f].most_common(1)[0][0], 'adj-adv')
            frames[kind].append((f, g, also(f, g)))
    out = [(f, g, '', 'trap', 'readstair') for f, g in TRAPS]
    for kind, n in QUOTA.items():  # a fixed pseudo-random order within each stratum
        out += [(f, g, a, kind, 'ud-ewt-2.18') for f, g, a in sorted(frames[kind], key=lambda r: hashlib.sha1(r[0].encode()).hexdigest())[:n]]
    return out, {r[0]: context[r[0], r[1]] for r in out if r[4] != 'readstair'}, {k: len(v) for k, v in sorted(frames.items())}


def score(lx, table, leave_out=()):
    """[rows, strict, accepted] for the traps, the gated UD rows and the homographs, and the misses of the gated rows. A row
    is accepted when the lookup gives its lemma or an audited `also` value, strict when it gives the lemma; homographs are
    only counted. Rows whose form is in leave_out are skipped."""
    groups, misses = collections.defaultdict(lambda: [0, 0, 0]), []
    for form, lemma, also, kind, _ in table:
        if form in leave_out:
            continue
        got = lx.predicted(form)
        group = groups[kind if kind in ('trap', 'homograph') else 'UD']
        group[0] += 1
        group[1] += got == lemma
        group[2] += got == lemma or got in also.split('|')
        if kind != 'homograph' and got != lemma and got not in also.split('|'):
            misses.append(f'{form} -> {got} (want {lemma})')
    return groups, misses


# --- Gates

def spearman(xs, ys):
    def ranks(v):
        order, r, i = sorted(range(len(v)), key=v.__getitem__), [0.0] * len(v), 0
        while i < len(v):
            j = i
            while j + 1 < len(v) and v[order[j + 1]] == v[order[i]]:
                j += 1
            for k in range(i, j + 1):
                r[order[k]] = (i + j) / 2  # ties share their mean rank
            i = j + 1
        return r
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    return sum((a - mx) * (b - my) for a, b in zip(rx, ry)) / math.sqrt(sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry))


def lemma_changes(old, new, renames):
    """Each form or lemma of the `old` tables whose lemma `new` changes, unless `renames` lists that change: (form, old, new).

    >>> old = Lookup({'glasses': 1, 'glass': 2}, {'men': 'man'})
    >>> new = Lookup({'glass': 2}, {'glasses': 'glass', 'men': 'man'})
    >>> lemma_changes(old, new, set())
    [('glasses', 'glasses', 'glass')]
    >>> lemma_changes(old, new, {('glasses', 'glasses', 'glass')})
    []
    """
    changes = ((f, old.lemma(f), new.lemma(f)) for f in sorted({*old.bands, *old.forms}))
    return [c for c in changes if c[1] != c[2] and c not in renames]


def gates(lx, vocab, ngsl_rank, lemma_of, overrides, table, texts, old, renames):
    """The conditions every build must meet; returns the measured values and the failures."""
    fail = [f'lookup gives {form} -> {lx.predicted(form)}, want {want}' for form, want in TRAPS if lx.predicted(form) != want]
    changed = lemma_changes(old, lx, renames)
    if changed:
        fail.append(f'lemma changes not listed in {RENAMES.relative_to(ROOT)} would strand saved words and iCloud records ({len(changed)}): '
                    + ', '.join(f'{form}: {a} -> {b}' for form, a, b in changed[:50]))
    # Agreement with NGSL, for each headword as the app reads it (found reads as find)
    order, by_band = {w: i for i, w in enumerate(lx.bands)}, collections.defaultdict(list)
    for w, r in ngsl_rank.items():
        by_band[(r - 1) // 1000 + 1].append(lx.band(lx.lemma(w)))
    share = lambda nb, top: sum(1 for b in by_band[nb] if b and b <= top) / len(by_band[nb])
    pairs = [(r, order[lx.lemma(w)]) for w, r in ngsl_rank.items() if lx.lemma(w) in order]
    values = {'NGSL band 1 in our bands 1-3': (share(1, 3), 0.99), 'NGSL band 2 in our bands 1-3': (share(2, 3), 0.90),
              'NGSL band 3 in our bands 1-5': (share(3, 5), 0.90), 'Spearman with NGSL rank': (spearman(*zip(*pairs)), 0.88)}
    n, strict, accepted = score(lx, table)[0]['UD']  # the floors of U-LEM-001 in ReadStairCoreTests
    values.update({'UD rows accepted': (accepted / n, 0.97), 'UD rows strict': (strict / n, 0.92)})
    fail += [f'{name} {v:.3f} < {floor}' for name, (v, floor) in values.items() if v < floor]
    per_band = collections.Counter(lx.bands.values())
    fail += [f'band {b} has {per_band[b]} lemmas' for b in range(1, SIZE // WIDTH + 1) if per_band[b] != WIDTH]
    for form, value in lx.forms.items():
        parts = value.split(' ')
        if value == form or (len(parts) > 1 and not all(any(a in lx.bands for a in p.split('|')) for p in parts)) \
                or (len(parts) == 1 and value not in lx.bands and value in lx.forms):
            fail.append(f'forms.tsv row {form} -> {value}')
    fail += [f'override {form} -> {lemma or form} has no effect, or its lemma reads as another' for form, lemma in overrides.items()
             if lx.lemma(form) != (lemma or form) or lemma_of.get(lemma or form, lemma or form) != (lemma or form)]
    real = collections.Counter(b for _, b in vocab if b)
    pseudo = [w for w, b in vocab if not b]
    fail += [f'vocab band {b} has {real[b]} words' for b in range(1, SIZE // WIDTH + 1) if real[b] != PER_BAND]
    if len(set(pseudo)) != PSEUDO or any(w in lx.bands or w in lx.forms for w in pseudo):
        fail.append(f'pseudowords are not {PSEUDO} unique non-words')
    for path, data in texts.items():
        text = data.decode('utf-8')
        if unicodedata.normalize('NFC', text) != text or '@' in text or CJK.search(text) or len(data) >= 1_000_000:
            fail.append(f'{path}: not NFC, or has @ or CJK text, or is 1 MB or more')
    return {name: v for name, (v, _) in values.items()}, fail


# --- Output files

WORDFREQ_CREDIT = ('wordfreq 3.1.1, Copyright 2022 Robyn Speer (https://github.com/rspeer/wordfreq, DOI 10.5281/zenodo.7199437), '
                   '`large_en` word list, licensed under CC BY-SA 4.0')
NGSL_CREDIT = ('New General Service List 1.2 by Browne, C., Culligan, B., and Phillips, J. '
               '(https://www.newgeneralservicelist.com/new-general-service-list), licensed under CC BY-SA 4.0')
WORDNET_CREDIT = 'WordNet 3.0, Princeton University (https://wordnet.princeton.edu/), under the WordNet 3.0 license'
UPSTREAM = """As wordfreq's license asks, ReadStair credits the sources wordfreq is built on:

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
"""
STANDARD_EBOOKS_CREDIT = """The sample book, `App/ReadStair/SampleBook/alice.epub`, holds Chapter I of *Alice's Adventures in Wonderland* by
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
"""
TEST_DATA_CREDITS = """### Universal Dependencies English Web Treebank

`Data/ud-ewt/lemma-500.tsv` takes words and their lemmas, never sentences, from the Universal Dependencies English Web
Treebank (UD English-EWT) v2.18 (https://github.com/UniversalDependencies/UD_English-EWT). From its README: "Universal
Dependencies English Web Treebank annotations © 2013-2021 by The Board of Trustees of The Leland Stanford Junior
University. All Rights Reserved. The annotations and database rights of the Universal Dependencies English Web Treebank
are licensed under a Creative Commons Attribution-ShareAlike 4.0 International License." and "The underlying texts come
from various sources collected for the LDC English Web Treebank. Some parts are in the public domain.
Portions may be © 2012 Google Inc., © 2011 Yahoo! Inc., © 2012 Trustees of the University of Pennsylvania and/or © other
original authors." The file, including its rows written for ReadStair, is distributed under CC BY-SA 4.0
(https://creativecommons.org/licenses/by-sa/4.0/legalcode).
"""


def lines(data):
    return data.count(b'\n') - 1  # rows below the header line


def tsv(header, pairs):
    return ('\n'.join([f'# {header}'] + [f'{a}\t{b}' for a, b in pairs]) + '\n').encode('utf-8')


def documents(tables, wordnet_license, counts):
    """LICENSE and ATTRIBUTION.md of the lexicon directory, and THIRD_PARTY_NOTICES.md for the app."""
    source = lambda path: f'`{path.relative_to(ROOT)}` (sha256 `{sha256(path.read_bytes())}`)'
    license_text = (
        'The data files in this directory (bands.tsv, forms.tsv and vocab.tsv) are derived from the wordfreq 3.1.1 data files\n'
        '(large_en), Copyright 2022 Robyn Speer, and from the New General Service List 1.2 by Browne, C., Culligan, B., and\n'
        'Phillips, J., both licensed under the Creative Commons Attribution-ShareAlike 4.0 International License, and from\n'
        'WordNet 3.0. The data files are distributed under the Creative Commons Attribution-ShareAlike 4.0 International\n'
        'License, together with the WordNet 3.0 license below.\n\n'
        'License text: https://creativecommons.org/licenses/by-sa/4.0/legalcode\n'
        'Sources and changes: see ATTRIBUTION.md in this directory.\n\n'
        f'{wordnet_license}\n'
        'This license applies only to the data files in this directory. ReadStair\'s source code is licensed under the PolyForm\n'
        'Noncommercial License 1.0.0 (see LICENSE at the repository root).\n')
    files = '\n'.join(f'| `{name}` | {lines(data):,} | {len(data):,} | `{sha256(data)}` |' for name, data in tables.items())
    attribution = f"""# Attribution: ReadStair lexicon

`bands.tsv`, `forms.tsv` and `vocab.tsv` are generated by `tools/make-lexicon.py` (no network access) from:

- {WORDFREQ_CREDIT}, read through the pip package `wordfreq=={WORDFREQ}`.
- {NGSL_CREDIT}: {source(NGSL / 'NGSL_12_stats.csv')} and {source(NGSL / 'NGSL_12_lemmatized_for_research.csv')}.
- {WORDNET_CREDIT} (see LICENSE): {source(WORDNET / 'wordnet-extract.tsv')}, extracted from `WordNet-3.0.tar.gz`
  (sha256 `{PINNED['WordNet-3.0.tar.gz']}`).
- Reviewed lemma decisions written for ReadStair: {source(OVERRIDES)}.

| File | Rows | Bytes | sha256 |
|---|---|---|---|
{files}

## Changes made

- Kept wordfreq's words made of Latin-script letters (accents allowed, as in "café"), optionally joined by apostrophes.
  wordfreq splits hyphenated words, so no row is hyphenated.
- Grouped word forms under lemmas (dictionary headwords). WordNet's irregular forms and suffix rules propose lemmas, with
  guards so that a word is not read as a different, shorter word (wed is not we, hiss is not his, james is not jam); NGSL
  word families choose between the proposals; a British spelling folds into an American one that shares a WordNet synset
  and is at least half as frequent (colour -> color); only a word's own paradigm folds into a function word; reviewed
  decisions follow; last, the -ings plural of an -ing form that reads as a verb stays a noun of its own (sayings).
- Summed the frequencies of the forms the app reads as each lemma, ranked the lemmas (number words first, since books print
  most numbers as digits) and replaced frequencies with bands: `band = rank // {WIDTH} + 1` for the {SIZE:,} most frequent
  lemmas (bands.tsv).
- forms.tsv lists each form of Zipf {MIN_ZIPF} or more that reads as another lemma: one in bands.tsv, or one beyond it that
  is itself that frequent (waistcoats -> waistcoat). A contraction lists its parts, alternatives joined by `|`
  (`can't` -> `can not`, `i'd` -> `i would|have`); a few old contractions are listed at any frequency (`ma'am` -> `madam`).
- vocab.tsv holds {PER_BAND} words for each band, picked by rule and spaced evenly by rank (WordNet senses and flags; NGSL
  band for bands 1-3; none offensive, made of an easier word, or rejected on review as a name), and {PSEUDO} pseudowords
  (band 0) made by swapping letter groups of easy words, kept only if they are not near a real word and are as word-like
  as real words of bands 21-25. Pseudowords approved on review stay while they pass these rules; ones rejected on review
  are left out.
- Decisions of this build: {', '.join(f'{v:,} {k}' for k, v in sorted(counts.items()))}.

Build constants: SIZE {SIZE}, WIDTH {WIDTH}, MIN_ZIPF {MIN_ZIPF}, RATIO {RATIO}, T_BASE {T_BASE}, DOM {DOM}, SEED {SEED}.

## Upstream sources credited by wordfreq

{UPSTREAM}"""
    notices = f"""# Third-party notices

ReadStair's source code is licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). The app ships two
pieces of third-party material: its word list, `{LEXICON}/`, which `tools/make-lexicon.py` derives from wordfreq, the New General Service List and
WordNet (the generator also writes this file), and its sample book, Chapter I of *Alice's Adventures in
Wonderland* as text in `App/ReadStair/SampleBook/alice.epub`, which is in the public domain. The word list is distributed
under the Creative Commons Attribution-ShareAlike 4.0 International License
(https://creativecommons.org/licenses/by-sa/4.0/legalcode), together with the WordNet 3.0 license.

The repository also holds test data that the app does not ship; its sources are credited below. Every directory of test
data has its own LICENSE and ATTRIBUTION.md.

## wordfreq

{WORDFREQ_CREDIT}.

{UPSTREAM}
## New General Service List

{NGSL_CREDIT}.

## WordNet

{WORDNET_CREDIT}:

```
{wordnet_license}```

## Standard Ebooks (sample book and test pages)

{STANDARD_EBOOKS_CREDIT}
## Test data, not shipped in the app

{TEST_DATA_CREDITS}"""
    return license_text.encode('utf-8'), attribution.encode('utf-8'), notices.encode('utf-8')


# --- Review lists (not committed)

def review_lists(directory, F, wn, lemma_of, bands, credit, pseudo_scores, vocab_stats, eval_rows, contexts):
    """folds.tsv: the most frequent folds that may give a misleading headword or band; pseudo.tsv: the pseudowords by score;
    with a draft evaluation set, lemma-500.tsv (the draft) and also.tsv: its rows with an `also` value, with a train sentence,
    for the audit (it shows no lexicon output)."""
    directory.mkdir(parents=True, exist_ok=True)
    ascending, flagged = sorted(credit.values()), []
    for form, lemma in lemma_of.items():
        if lemma == form or lemma in wn.twins.get(form, []):
            continue  # British -> American is a settled convention
        s, lemma_band = wn.senses.get(form, {}), bands.get(lemma)
        form_band = (len(ascending) - bisect.bisect_right(ascending, F[form])) // WIDTH + 1  # the form's band on its own
        why = [name for name, hit in (
            ('senses', s.get('noun', 0) + s.get('adj', 0) >= 2),  # a noun or adjective in its own right (meeting, tired)
            ('s-noun', form.endswith('s') and s.get('noun') and not wn.senses.get(lemma, {}).get('noun')),  # economics
            ('band', lemma_band and form_band - lemma_band >= 2),  # much rarer than its lemma (dogged, glasses)
            ('irregular', any(t != lemma for p in POS for t in wn.exc[p].get(form, [])))) if hit]  # leaves: leaf or leave
        if why:
            flagged.append((F[form], form, lemma, form_band, lemma_band or '', f'{F[form] / credit[lemma]:.3f}',
                            ','.join(f'{LETTER[p]}{s[p]}' for p in POS if s.get(p)), '+'.join(why)))
    lines = ['form\tlemma\tform_band\tlemma_band\tform_freq_share\twordnet_pos_senses\twhy']
    lines += ['\t'.join(map(str, row[1:])) for row in sorted(flagged, reverse=True)[:400]]
    (directory / 'folds.tsv').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    lines = [f'# threshold {vocab_stats["floor"]:.3f} (25th percentile of real words ranked 20,001-25,000; quartiles '
             f'{", ".join(f"{q:.3f}" for q in vocab_stats["held_out_quartiles"])})', 'pseudoword\tscore\treview']
    lines += [f'{w}\t{s:.3f}\t{"approved" if w in APPROVED else "new"}'
              for w, s in sorted(pseudo_scores.items(), key=lambda kv: (kv[1], kv[0]))]
    (directory / 'pseudo.tsv').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    if eval_rows:
        lines = ['form\tlemma\talso\tkind\tsource'] + ['\t'.join(r) for r in eval_rows]
        (directory / 'lemma-500.tsv').write_text('\n'.join(lines) + '\n', encoding='utf-8')
        lines = ['form\tlemma\talso\tkind\tsentence']
        lines += ['\t'.join([f, g, a, k, contexts[f]]) for f, g, a, k, src in eval_rows if a and src != 'readstair']
        (directory / 'also.tsv').write_text('\n'.join(lines) + '\n', encoding='utf-8')


# --- Main

def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='rebuild into a temporary directory and byte-compare')
    parser.add_argument('--extract-wordnet', metavar='TGZ', type=Path, help='rewrite the WordNet extract from WordNet-3.0.tar.gz')
    parser.add_argument('--review', metavar='DIR', type=Path, help='directory for the review lists')
    parser.add_argument('--ud', metavar='DIR', type=Path, help='with --review: directory with the UD English-EWT 2.18 .conllu files')
    args = parser.parse_args()
    if args.check and (args.ud or args.review or args.extract_wordnet):
        parser.error('--check writes nothing, so it takes no other option')
    if args.ud and not args.review:
        parser.error('--ud writes its draft into the --review directory')
    if args.check and doctest.testmod().failed:
        sys.exit('Doctests failed')
    every, F = wordfreq_forms()
    if args.extract_wordnet:
        data = extract_wordnet(args.extract_wordnet, F)
        (WORDNET / 'wordnet-extract.tsv').write_bytes(data)
        print(f'wordnet-extract.tsv: {lines(data):,} rows, {len(data):,} bytes, sha256 {sha256(data)}')
        return

    wn = WordNet(WORDNET / 'wordnet-extract.tsv')
    U, ngsl_rank, family = load_ngsl()
    overrides = load_overrides()
    lemma_of, counts = lemmatize(F, wn, U, family, overrides)
    bands, credit, contractions = rank(F, lemma_of)
    forms = form_rows(F, lemma_of, bands, contractions)
    vocab, pseudo_scores, vocab_stats = vocabulary(bands, forms, wn, ngsl_rank, every)
    counts['contractions'] = len(contractions)
    source = 'tools/make-lexicon.py; wordfreq 3.1.1, NGSL 1.2, WordNet 3.0; CC BY-SA 4.0, see LICENSE'
    tables = {
        'bands.tsv': tsv(f'ReadStair lexicon ({source}): lemma<TAB>band, {SIZE:,} lemmas by frequency, band = rank // {WIDTH} + 1',
                         bands.items()),
        'forms.tsv': tsv(f'ReadStair lexicon ({source}): form<TAB>lemma, or a contraction\'s parts separated by spaces, '
                         'alternatives joined by |', forms.items()),
        'vocab.tsv': tsv(f'ReadStair lexicon ({source}): word<TAB>band, {PER_BAND} words for each band by rank, then {PSEUDO} '
                         'pseudowords (band 0)', vocab)}
    license_text, attribution, notices = documents(tables, (WORDNET / 'LICENSE').read_text(encoding='utf-8'), counts)
    outputs = {LEXICON / name: data for name, data in tables.items()}
    outputs.update({LEXICON / 'LICENSE': license_text, LEXICON / 'ATTRIBUTION.md': attribution, NOTICES: notices})

    lx, table = Lookup(bands, forms), [tuple(r) for r in rows(EVAL_SET)[1:]]
    values, fail = gates(lx, vocab, ngsl_rank, lemma_of, overrides, table, outputs, committed(), load_renames())
    if fail:
        sys.exit('Gates failed, nothing written:\n  ' + '\n  '.join(fail))
    print(f'{len(F):,} forms -> {len(credit):,} lemmas; ' + ', '.join(f'{v:,} {k}' for k, v in sorted(counts.items())))
    print('gates: ' + ', '.join(f'{k} {v:.3f}' for k, v in values.items()))
    for name, leave_out in (('', ()), (' without the forms overrides.tsv decides', overrides)):
        groups, misses = score(lx, table, leave_out)
        (t, t_ok, _), (n, strict, ok), (h, h_ok, _) = groups['trap'], groups['UD'], groups['homograph']
        print(f'{EVAL_SET.relative_to(ROOT)}{name}: traps {t_ok}/{t}; UD rows accepted {ok}/{n} = {ok / n:.2%}, strict '
              f'{strict}/{n} = {strict / n:.2%}; homographs read as the majority lemma {h_ok}/{h}; misses: {", ".join(misses) or "none"}')
    print(f'vocab: pools {vocab_stats["pool"]}; pseudowords from {vocab_stats["tries"]:,} tries, rejected {vocab_stats["rejected"]}')

    target = Path(tempfile.mkdtemp(prefix='make-lexicon-')) if args.check else ROOT
    for path, data in outputs.items():
        (target / path).parent.mkdir(parents=True, exist_ok=True)
        (target / path).write_bytes(data)
        print(f'{path}: {len(data):,} bytes, sha256 {sha256(data)}')
    if args.check:
        differ = [p for p in outputs if not (ROOT / p).exists() or (ROOT / p).read_bytes() != outputs[p]]
        if differ:
            sys.exit(f'Differs from the rebuild (kept in {target}): ' + ', '.join(map(str, differ)))
        shutil.rmtree(target)
        print('check: the committed files match the rebuild')

    eval_rows, contexts = [], {}
    if args.ud:
        eval_rows, contexts, frames = eval_set(args.ud, every, wn, family)
        same = [(f, g, k, s) for f, g, _, k, s in eval_rows] == [(f, g, k, s) for f, g, _, k, s in table]
        print(f'draft evaluation set: {len(eval_rows)} rows, {sum(1 for r in eval_rows if r[2])} with an unaudited `also`, '
              f'strata available {frames}; its form, lemma, kind and source columns '
              f'{"match" if same else "differ from"} {EVAL_SET.relative_to(ROOT)}')
    if args.review:
        review_lists(args.review, F, wn, lemma_of, bands, credit, pseudo_scores, vocab_stats, eval_rows, contexts)
        print(f'review lists written to {args.review}')


if __name__ == '__main__':
    main()
