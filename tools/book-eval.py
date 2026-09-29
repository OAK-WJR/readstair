#!/usr/bin/env python3
"""Score ReadStair's underlines against one reader's own corrections on pages of printed books.

How the data comes about: the reader imports pages of their own books and, on each page, taps I Know This on an underlined word
they know and Mark as New on a word they don't know that was not underlined. After that every page shows exactly the words the
reader does not know. The app stores the word states (wordEntry, one row per lemma), the recognized words of each page with their
kind and band (pageText) and the level (profile), but never the underlines themselves. This script works them out again with the
app's rule (Annotator.isMarked):

  before any correction   kind is word and (no band or band > level)                    what the level alone underlines
  after the corrections   learning: underlined; known: not; no state: as above          what the reader does not know

and compares the two. Counts are of printed words (a word printed three times counts three times); punctuation is left out.

  hit rate      share of the words the reader did not know that were underlined     target >= 80%
  false marks   share of the underlined words the reader knew                        target <= 20%
  density       underlined words / words on the page                                 target 1% to 3%

Usage:
  python3 tools/book-eval.py PATH [--level N] [--book TEXT ...]
  python3 tools/book-eval.py --self-test [--repo DIR]

PATH is the container Xcode downloads (*.xcappdata), any folder inside it, or ReadStair.sqlite itself. The database is copied with its
-wal file (where the latest changes can still be) into a temporary folder and read there, so the download is never changed. The report
shows single words, book titles and page numbers, never a sentence from a book. Python 3 standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import re
import shutil
import sqlite3
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

# The app's constants; --self-test checks them against the Swift sources
LEVELS = range(1, 26)  # Profile.levels, in thousands of words
DEFAULT_LEVEL = 3  # Profile.defaultLevel: the level with no saved profile, and the placeholder of a skipped test
ANCHORS = (1, 2, 3, 5, 8, 12)  # LevelLadder.anchors: the levels the app offers
HIT_TARGET, FALSE_TARGET, DENSITY_RANGE = 0.80, 0.20, (0.01, 0.03)  # ReadStair's targets for underlining
TABLES = ('book', 'page', 'pageText', 'wordEntry', 'profile')


class EvalError(Exception):
    """A problem with the input: printed as one line, without a traceback."""


class SelfTestFailure(Exception):
    """A failed self-test check. Raised explicitly, not with assert, so `python3 -O` cannot skip the checks."""


# MARK: - Reading the database

def find_database(path: Path) -> Path:
    if path.is_file():
        return path
    if not path.is_dir():
        raise EvalError(f'{path} does not exist')
    found = sorted(p for p in path.rglob('ReadStair.sqlite') if p.is_file())
    if len(found) != 1:
        raise EvalError(f'expected one ReadStair.sqlite under {path}, found {len(found)}' + ''.join(f'\n  {p}' for p in found))
    return found[0]


def open_copy(database: Path, folder: Path) -> sqlite3.Connection:
    """Copies the database and its -wal file into `folder` and opens the copy. The -shm file is only an index SQLite rebuilds."""
    copy = folder / 'ReadStair.sqlite'
    shutil.copyfile(database, copy)
    wal = database.with_name(database.name + '-wal')
    if wal.exists():
        shutil.copyfile(wal, folder / 'ReadStair.sqlite-wal')
    hint = '' if wal.exists() else f'; {wal.name} is missing: copy it together with {database.name}, the app keeps recent changes in it'
    connection = sqlite3.connect(copy)
    try:
        try:
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        except sqlite3.DatabaseError as error:
            raise EvalError(f'{database} is not a readable SQLite database ({error}){hint}')
        missing = [table for table in TABLES if table not in tables]
        if missing:
            raise EvalError(f'{database} has no {", ".join(missing)} table: not a ReadStair database{hint}')
        if hint and connection.execute('SELECT COUNT(*) FROM page').fetchone()[0] == 0:
            raise EvalError(f'{database} has no pages{hint}')
    except BaseException:
        connection.close()
        raise
    return connection


def state_key(lemma: str) -> str:
    """SyncRules.lemmaKey: how wordEntry keys a word (lowercased, then Unicode NFC)."""
    return unicodedata.normalize('NFC', lemma.lower())


def core(text: str) -> str:
    """PageWord.core: the printed word without leading and trailing punctuation (letters, marks and digits are kept, like
    CharacterSet.alphanumerics)."""
    keep = [unicodedata.category(character)[0] in 'LMN' for character in text]
    start, end = 0, len(text)
    while start < end and not keep[start]:
        start += 1
    while end > start and not keep[end - 1]:
        end -= 1
    return text[start:end]


@dataclass
class Word:
    """A printed word on an evaluated page (punctuation is left out)."""
    page: str  # label, e.g. "B1 p3"
    key: str  # state key of its lemma
    form: str  # as printed, without punctuation
    kind: str  # word, name or number
    band: int | None
    unknown: bool  # underlined once the reader's corrections apply: a word the reader does not know

    def marked(self, level: int) -> bool:
        """What the level alone underlines: Annotator.isMarked with no state."""
        return shown(self.kind, self.band, level, None)


@dataclass
class Evaluation:
    database: Path
    schema: int
    level: int
    level_line: str
    books: list  # (label, title, evaluated pages)
    pages: list  # (label, [Word])
    notes: list

    @property
    def words(self) -> list:
        return [word for _, words in self.pages for word in words]


def shown(kind: str, band: int | None, level: int, state: str | None) -> bool:
    """Annotator.isMarked: learning is always underlined, known never; with no state, a plain word whose band is above the level or
    that has no band."""
    if state in ('learning', 'known'):
        return state == 'learning'
    return kind == 'word' and (band is None or band > level)


def when(seconds: float) -> str:
    return datetime.fromtimestamp(seconds).strftime('%Y-%m-%d %H:%M:%S')


def load(database: Path, connection: sqlite3.Connection, level: int | None, book_filters: list) -> Evaluation:
    notes = []
    schema = connection.execute('PRAGMA user_version').fetchone()[0]
    profile = connection.execute('SELECT level, updatedAt FROM profile WHERE id = 1').fetchone()
    chosen_level_time = profile[1] if level is None and profile is not None and profile[1] > 0 else None
    if level is not None:
        level_line = f'{level} ({level},000 words), as given with --level'
    elif profile is None:
        level = DEFAULT_LEVEL
        level_line = f'{level} ({level},000 words), the default: no level saved (the level test was never finished or skipped)'
    else:
        level = profile[0]
        saved = 'the default, because the level test was skipped' if profile[1] == 0 else f'saved {when(profile[1])}'
        level_line = f'{level} ({level},000 words), {saved}'
    states = {}
    for key, state, source, updated in connection.execute('SELECT lemma, state, source, updatedAt FROM wordEntry'):
        states[state_key(key)] = (state, source, updated)

    books = connection.execute('SELECT id, title FROM book ORDER BY createdAt, rowid').fetchall()
    labels = {book_id: f'B{number}' for number, (book_id, _) in enumerate(books, 1)}
    chosen = [(book_id, title) for book_id, title in books
              if not book_filters or any(f.lower() in title.lower() or f.upper() == labels[book_id] for f in book_filters)]
    if not chosen:
        raise EvalError('no book matches ' + ', '.join(book_filters) if book_filters else 'the database has no books')

    evaluated_books, pages, versions, skipped = [], [], set(), 0
    for book_id, title in chosen:
        rows = connection.execute("""
            SELECT page.status, pageText.schemaVersion, pageText.json FROM page LEFT JOIN pageText ON pageText.pageID = page.id
            WHERE page.bookID = ? ORDER BY page."index"
            """, (book_id,)).fetchall()
        count = 0
        for position, (status, version, blob) in enumerate(rows, 1):
            try:
                text = json.loads(blob) if status == 'recognized' and blob is not None else None
            except (ValueError, UnicodeDecodeError):
                text = None
            label = f'{labels[book_id]} p{position}'
            words = []
            for word in (text or {}).get('words', []):
                kind = word.get('kind')
                if kind not in ('word', 'name', 'number'):
                    continue
                key, band = state_key(word.get('lemma', '')), word.get('band')
                state = states.get(key, (None,))[0]
                words.append(Word(label, key, core(word.get('surface', '')) or key, kind, band, shown(kind, band, level, state)))
            if not words:
                skipped += 1
                continue
            versions.add(version)
            pages.append((label, words))
            count += 1
        evaluated_books.append((labels[book_id], title, count))
    if skipped:
        notes.append(f'{skipped} page(s) left out: not read yet, reading failed, or no words found.')
    if not pages:
        raise EvalError('no page with recognized words in the chosen books')
    if len(versions) > 1:
        notes.append(f'Pages were analyzed by different app versions (pageText versions {sorted(versions)}): '
                     'was the app updated during the evaluation?')

    keys = {word.key for _, words in pages for word in words}
    corrected = [states[key][2] for key in keys if key in states and states[key][1] == 'card']
    if not any(key in states for key in keys):
        notes.append('No word on these pages has a state: no corrections were saved. If you made some, the last one may still have '
                     'been waiting in the undo toast, or ReadStair.sqlite-wal was not copied.')
    elif chosen_level_time is not None and corrected and chosen_level_time > min(corrected):
        notes.append(f'The level was saved ({when(chosen_level_time)}) after the first correction ({when(min(corrected))}). If you '
                     'read the pages at another level, run again with --level set to that level.')
    return Evaluation(database, schema, level, level_line, evaluated_books, pages, notes)


# MARK: - Scoring

@dataclass
class Tally:
    words: int = 0
    marked: int = 0  # underlined by the level alone
    unknown: int = 0  # words the reader did not know
    hits: int = 0
    knew: int = 0  # underlined, but the reader knew them
    missed: int = 0  # not underlined, but new to the reader

    @classmethod
    def of(cls, words: list, level: int) -> Tally:
        tally = cls()
        for word in words:
            marked = word.marked(level)
            tally.words += 1
            tally.marked += marked
            tally.unknown += word.unknown
            tally.hits += marked and word.unknown
            tally.knew += marked and not word.unknown
            tally.missed += word.unknown and not marked
        return tally

    @property
    def hit_rate(self) -> float | None:
        return self.hits / self.unknown if self.unknown else None

    @property
    def false_rate(self) -> float | None:
        return self.knew / self.marked if self.marked else None

    @property
    def density(self) -> float | None:
        return self.marked / self.words if self.words else None


def to_fix(words: list, level: int) -> dict:
    """The words the reader would have had to correct at `level`, by state key: each needs one correction wherever it is printed."""
    fixes = {}
    for word in words:
        if word.marked(level) != word.unknown:
            fixes.setdefault(word.key, []).append(word)
    return fixes


def best_level(words: list, level: int) -> int:
    """Of the levels the app offers, the one with the fewest words to correct; on a tie the one nearest the level used, then the
    lower one. Only offered levels count, since the test and the settings can only give one of those."""
    return min(ANCHORS, key=lambda candidate: (len(to_fix(words, candidate)), abs(candidate - level), candidate))


def likely_range(k: int, n: int) -> tuple:
    """95% Wilson score interval of k out of n. Somewhat too narrow here, since a word printed twice is not two independent answers."""
    z = 1.96
    p = k / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return max(0.0, centre - half), min(1.0, centre + half)


def verdict(value: float, low: float, high: float, target: float, at_least: bool) -> str:
    ok = (lambda x: x >= target) if at_least else (lambda x: x <= target)
    if ok(value):
        return 'met' if ok(low) and ok(high) else 'met, but not certain'
    return 'missed' if not ok(low) and not ok(high) else 'missed, but not certain'


# MARK: - Report

def percent(value: float | None, digits: int = 0) -> str:
    return '-' if value is None else f'{value * 100:.{digits}f}%'


def hint(word: Word) -> str:
    if word.kind == 'name':
        return 'read as a name'
    if word.kind == 'number':
        return 'read as a number'
    if '-' in word.form:
        return 'hyphenated: joined or split right?'
    return 'not in the lexicon: misread, or a form it lacks?' if word.band is None else ''


def report(evaluation: Evaluation, out) -> None:
    level, words = evaluation.level, evaluation.words
    print(f'ReadStair book evaluation: {evaluation.database}', file=out)
    print(f'Database schema version {evaluation.schema}. Level used: {evaluation.level_line}.', file=out)
    for label, title, count in evaluation.books:
        print(f'  {label} = {title} ({count} page{"s" if count != 1 else ""})', file=out)
    for note in evaluation.notes:
        print(f'Note: {note}', file=out)

    print('\nPer page. Marked: underlined by the level alone. New: words you did not know. Knew: underlined but known (I Know This).',
          file=out)
    print('Missed: new to you but not underlined (Mark as New). Hit, False, Density: the three measures below, for this page.', file=out)
    columns = f'{"Page":<10}{"Words":>7}{"Marked":>8}{"New":>6}{"Knew":>6}{"Missed":>8}{"Hit":>7}{"False":>7}{"Density":>9}'
    print(columns, file=out)
    in_range = 0
    for label, page_words in evaluation.pages + [('All', words)]:
        t = Tally.of(page_words, level)
        if label != 'All' and DENSITY_RANGE[0] <= t.density <= DENSITY_RANGE[1]:
            in_range += 1
        print(f'{label:<10}{t.words:>7}{t.marked:>8}{t.unknown:>6}{t.knew:>6}{t.missed:>8}{percent(t.hit_rate):>7}'
              f'{percent(t.false_rate):>7}{percent(t.density, 1):>9}', file=out)

    total = Tally.of(words, level)
    print('\nAgainst the targets (hit rate >= 80%, false marks <= 20%, density 1-3%), counting every printed word:', file=out)
    for name, k, n, target, at_least in (('Hit rate', total.hits, total.unknown, HIT_TARGET, True),
                                         ('False marks', total.knew, total.marked, FALSE_TARGET, False)):
        sign = '>=' if at_least else '<='
        if n == 0:
            print(f'  {name:<12}{"-":>6}   no words to count   target {sign} {target:.0%}', file=out)
            continue
        low, high = likely_range(k, n)
        print(f'  {name:<12}{percent(k / n):>6}   likely {low * 100:.0f}-{high * 100:.0f}%   target {sign} {target:.0%}   '
              f'{verdict(k / n, low, high, target, at_least)}', file=out)
    ok = DENSITY_RANGE[0] <= total.density <= DENSITY_RANGE[1]
    print(f'  {"Density":<12}{percent(total.density, 1):>6}   {in_range} of {len(evaluation.pages)} pages within 1-3%   '
          f'target 1-3%   {"met" if ok else "missed"}', file=out)
    print(f'  New to you: {percent(total.unknown / total.words, 1)} of all words (what a perfect underline would mark).', file=out)

    best = best_level(words, level)
    print('\nIf the level had been different (your answers stay as they are). To fix: different words you would have had to correct.',
          file=out)
    print('offered: one of the six levels the app offers. used: the level of this report. best: the offered level with the fewest '
          'to fix.', file=out)
    print(f'{"Level":>7}{"Hit":>7}{"False":>7}{"Density":>9}{"To fix":>8}', file=out)
    for candidate in range(LEVELS.start, max(ANCHORS[-1], level) + 1):
        t = Tally.of(words, candidate)
        marks = [name for name, on in (('offered', candidate in ANCHORS), ('used', candidate == level), ('best', candidate == best)) if on]
        row = (f'{candidate:>7}{percent(t.hit_rate):>7}{percent(t.false_rate):>7}{percent(t.density, 1):>9}'
               f'{len(to_fix(words, candidate)):>8}   {", ".join(marks)}')
        print(row.rstrip(), file=out)

    fixes = to_fix(words, level)
    for title, knew in (('Underlined, but you knew them (I Know This)', True), ('New to you, but not underlined (Mark as New)', False)):
        group = sorted(((key, found) for key, found in fixes.items() if found[0].marked(level) == knew),
                       key=lambda item: (-len(item[1]), item[0]))
        print(f'\n{title}: {len(group)} word{"s" if len(group) != 1 else ""}', file=out)
        if not group:
            continue
        print(f'  {"Word":<20}{"Band":>5}{"Times":>7}  {"Pages":<22}{"Printed as":<24}Check', file=out)
        for key, found in group:
            first = found[0]
            pages = sorted({word.page for word in found}, key=lambda label: [int(n) for n in re.findall(r'\d+', label)])
            shown_pages = ', '.join(pages[:3]) + (f' +{len(pages) - 3}' if len(pages) > 3 else '')
            forms = ', '.join(sorted({unicodedata.normalize('NFC', word.form) for word in found})[:3])
            band = '-' if first.band is None else str(first.band)
            print(f'  {key:<20}{band:>5}{len(found):>7}  {shown_pages:<22}{forms:<24}{hint(first)}'.rstrip(), file=out)


def evaluate(path: Path, level: int | None = None, book_filters: tuple = ()) -> tuple:
    """Reads the database at `path` (see find_database) and returns (evaluation, report text)."""
    if level is not None and level not in LEVELS:
        raise EvalError(f'--level must be between {LEVELS.start} and {LEVELS.stop - 1}')
    database = find_database(path)
    with tempfile.TemporaryDirectory() as folder:
        connection = open_copy(database, Path(folder))
        try:
            evaluation = load(database, connection, level, list(book_filters))
        finally:
            connection.close()
    out = io.StringIO()
    report(evaluation, out)
    return evaluation, out.getvalue()


# MARK: - Self-test

def swift_source(repo: Path, name: str) -> str:
    path = repo / 'Packages/ReadStairCore/Sources/ReadStairCore' / name
    if not path.exists():
        raise EvalError(f'{path} not found: pass --repo with the ReadStair repository')
    return path.read_text(encoding='utf-8')


def migrations(repo: Path) -> list:
    """The schema scripts of BookStore.migrations, taken from the Swift source so the test database always has the app's schema."""
    source = swift_source(repo, 'BookStore.swift')
    start = source.index('static let migrations: [String] = [')
    scripts = re.findall(r'"""\n(.*?)\n[ \t]*"""', source[start:source.index('\n    ]\n', start)], re.S)
    if not scripts or any('\\' in script for script in scripts):
        raise SelfTestFailure('BookStore.migrations: no scripts found, or escapes this cannot read')
    return scripts


def make_database(folder: Path, scripts: list, profile, books: list, entries: list) -> sqlite3.Connection:
    """A database like the app's, left open in WAL mode so its data stays in the -wal file as on a phone. `books`: (title, pages),
    each page a list of words (surface, lemma, kind, band) or None for a page not read yet. `entries`: (lemma, state, source, band,
    updatedAt)."""
    folder.mkdir(parents=True)
    connection = sqlite3.connect(folder / 'ReadStair.sqlite', isolation_level=None)
    connection.execute('PRAGMA journal_mode = WAL')
    for version, script in enumerate(scripts, 1):
        connection.executescript(f'BEGIN; {script}; PRAGMA user_version = {version}; COMMIT;')
    connection.execute('BEGIN')
    for number, (title, pages) in enumerate(books):
        book_id = f'00000000-0000-4000-8000-{number:012d}'
        connection.execute('INSERT INTO book (id, title, createdAt) VALUES (?, ?, ?)', (book_id, title, 1_790_000_000.0 + number))
        for index, words in enumerate(pages):
            page_id = f'00000000-0000-4000-9000-{number * 100 + index:012d}'
            connection.execute('INSERT INTO page (id, bookID, "index", width, height, status, attempts) VALUES (?, ?, ?, 1400, 2100, ?, 1)',
                               (page_id, book_id, index, 'pending' if words is None else 'recognized'))
            if words is None:
                continue
            # Encoded like Swift's JSONEncoder for PageText: a nil band is left out; the JSON is stored as a blob
            quad = {'topLeft': [0.1, 0.1], 'topRight': [0.2, 0.1], 'bottomRight': [0.2, 0.12], 'bottomLeft': [0.1, 0.12]}
            encoded = [dict({'surface': s, 'lemma': l, 'kind': k, 'sentence': 0, 'quads': [quad]}, **({} if b is None else {'band': b}))
                       for s, l, k, b in words]
            text = {'words': encoded, 'sentences': ['Sentinel sentence that must never be printed.']}
            connection.execute('INSERT INTO pageText (pageID, schemaVersion, json) VALUES (?, 2, ?)',
                               (page_id, json.dumps(text).encode()))
    if profile is not None:
        connection.execute('INSERT INTO profile (id, level, updatedAt) VALUES (1, ?, ?)', profile)
    for lemma, state, source, band, updated in entries:
        connection.execute('INSERT INTO wordEntry (lemma, state, source, band, updatedAt, firstSentence) VALUES (?, ?, ?, ?, ?, ?)',
                           (lemma, state, source, band, updated, 'Sentinel sentence that must never be printed.'))
    connection.execute('COMMIT')
    return connection


def self_test(repo: Path) -> None:
    checks = 0

    def check(condition, message: str) -> None:
        nonlocal checks
        checks += 1
        if not condition:
            raise SelfTestFailure(message)

    # The mirrored constants still match the app
    store, ladder = swift_source(repo, 'BookStore.swift'), swift_source(repo, 'VocabTest.swift')
    levels = re.search(r'static let levels = (\d+)\.\.\.(\d+)', store)
    check(levels and range(int(levels[1]), int(levels[2]) + 1) == LEVELS, 'LEVELS differs from Profile.levels')
    default = re.search(r'static let defaultLevel = (\d+)', store)
    check(default and default[1] == str(DEFAULT_LEVEL), 'DEFAULT_LEVEL differs from Profile.defaultLevel')
    anchors = re.search(r'static let anchors = \[([\d, ]+)\]', ladder)
    check(anchors and tuple(int(a) for a in anchors[1].split(',')) == ANCHORS, 'ANCHORS differs from LevelLadder.anchors')

    T = 1_790_000_100.0
    # OCR can return a base letter plus a combining accent; the store keys it precomposed. Written as escapes so an editor
    # cannot quietly merge them, which would leave nothing for the NFC check to catch.
    cafe, cafe_key = 'cafe\u0301', 'caf\u00e9'
    check(cafe != cafe_key and state_key(cafe) == cafe_key, 'the accent fixture must differ from its stored key until NFC')
    book_a = ('Test Novel', [
        [('The', 'the', 'word', 1), ('reluctant', 'reluctant', 'word', 8), ('gazed', 'gaze', 'word', 6), ('at', 'at', 'word', 1),
         ('Alice', 'alice', 'name', 4), ('quietly', 'quietly', 'word', 2), (',', '', 'punct', None), ('tbe', 'tbe', 'word', None),
         ('42', '42', 'number', None), ('gazed.', 'gaze', 'word', 6), ('wonderful', 'wonderful', 'word', 3)],
        [('reluctant', 'reluctant', 'word', 8), ('sombre', 'sombre', 'word', 12), ('was', 'be', 'word', 1), ('Rose', 'rose', 'name', 3),
         ('the', 'the', 'word', 1), ('murmured', 'murmur', 'word', 5)],
        None,
    ])
    book_b = ('Second Book', [
        [('The', 'the', 'word', 1), ('well-known', 'well-known', 'word', None), (cafe.capitalize(), cafe, 'word', 7),
         ('is', 'be', 'word', 1), ('open', 'open', 'word', 1), ('ominous', 'ominous', 'word', 9)],
    ])
    # murmur has no state: underlined at level 3 and left alone, so new to the reader at 3, known if read at 8
    entries = [('reluctant', 'known', 'card', 8, T + 10), ('gaze', 'learning', 'lookup', 6, T + 5), ('tbe', 'known', 'card', None, T + 20),
               ('quietly', 'learning', 'card', 2, T + 30), ('sombre', 'learning', 'lookup', 12, T + 40),
               ('rose', 'learning', 'card', 3, T + 50), ('well-known', 'known', 'card', None, T + 60),
               (cafe_key, 'known', 'card', 7, T + 70), ('ominous', 'known', 'card', 9, T + 75), ('zebra', 'learning', 'card', 9, T + 80)]

    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        scripts = migrations(repo)
        phone = make_database(root / 'phone', scripts, (3, T), [book_a, book_b], entries)
        # What Download Container gives: the store's folder inside the package, the database with its -wal file
        container = root / 'app.readstair 2026-10-01.xcappdata'
        store_folder = container / 'AppData/Library/Application Support/ReadStair'
        store_folder.mkdir(parents=True)
        for name in ('ReadStair.sqlite', 'ReadStair.sqlite-wal'):
            shutil.copyfile(root / 'phone' / name, store_folder / name)
        check((store_folder / 'ReadStair.sqlite-wal').stat().st_size > 0, 'the fixture should keep its data in the -wal file')
        def digest() -> list:
            return [hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(store_folder.iterdir())]
        before = digest()

        evaluation, text = evaluate(container)
        words = evaluation.words
        check(digest() == before and len(before) == 2, 'the download must stay unchanged')
        check(evaluation.level == 3 and evaluation.schema == len(scripts), f'level {evaluation.level}, schema {evaluation.schema}')
        check([label for label, _ in evaluation.pages] == ['B1 p1', 'B1 p2', 'B2 p1'], 'pages, labels or order')
        check(any('1 page(s) left out' in note for note in evaluation.notes), 'the unread page should be reported')
        check(not any('level was saved' in note for note in evaluation.notes), 'no level warning expected')
        pages = {label: Tally.of(page_words, 3) for label, page_words in evaluation.pages}
        check(pages['B1 p1'] == Tally(words=10, marked=4, unknown=3, hits=2, knew=2, missed=1), f'B1 p1: {pages["B1 p1"]}')
        check(pages['B1 p2'] == Tally(words=6, marked=3, unknown=3, hits=2, knew=1, missed=1), f'B1 p2: {pages["B1 p2"]}')
        check(pages['B2 p1'] == Tally(words=6, marked=3, unknown=0, hits=0, knew=3, missed=0), f'B2 p1 (NFC match): {pages["B2 p1"]}')
        total = Tally.of(words, 3)
        check(total == Tally(words=22, marked=10, unknown=6, hits=4, knew=6, missed=2), f'overall: {total}')
        check((total.hit_rate, total.false_rate, total.density) == (4 / 6, 6 / 10, 10 / 22), f'overall rates: {total}')
        expected_fixes = {1: 7, 2: 8, 3: 7, 4: 7, 5: 8, 6: 9, 7: 8, 8: 7, 9: 6, 11: 6, 12: 7, 25: 7}
        found_fixes = {lv: len(to_fix(words, lv)) for lv in expected_fixes}
        check(found_fixes == expected_fixes, f'words to fix by level: {found_fixes}')
        # Levels 1, 3, 8 and 12 tie at 7 among the offered ones; 9 needs only 6 but is not offered
        check(best_level(words, 3) == 3, f'best level {best_level(words, 3)}')
        check(Tally.of(words, 9) == Tally(words=22, marked=3, unknown=6, hits=1, knew=2, missed=5), f'level 9: {Tally.of(words, 9)}')
        fixes = to_fix(words, 3)
        expected_words = ['reluctant', 'tbe', 'well-known', cafe_key, 'ominous', 'quietly', 'rose']
        check(sorted(fixes) == sorted(expected_words), f'fixes: {sorted(fixes)}')
        check(len(fixes['reluctant']) == 2 and hint(fixes['tbe'][0]).startswith('not in the lexicon'), 'reluctant twice; tbe hint')
        check(hint(fixes['rose'][0]) == 'read as a name' and hint(fixes['well-known'][0]).startswith('hyphenated'), 'hints')
        check('\n     12 ' in text and '\n     13 ' not in text, 'the level table ends at the highest level offered')
        check(fixes[cafe_key][0].form == cafe.capitalize(), 'the combining accent is part of the printed word')
        check('Sentinel' not in text, 'the report must never print a sentence from a book')
        check(re.search(r'Hit rate\s+67%', text) and re.search(r'False marks\s+60%', text), 'report text:\n' + text)
        check(re.search(r'\n\s+3\s+67%\s+60%\s+45\.5%\s+7\s+offered, used, best\n', text), 'level 3 row:\n' + text)
        check(re.search(r'\n\s+9\s+17%\s+67%\s+13\.6%\s+6\n', text), 'level 9 row: not offered, so never best')
        check(not re.search(r' +\n', text), 'no trailing spaces')

        # The best offered level: the nearest of a tie wins, and a better level the app does not offer (6) is passed over.
        # At 1-3 both p (band 4) and q (band 6) are underlined though known; at 5 only q is; from 7 up, r (band 7) is not
        # underlined though new; at 6 nothing is wrong.
        unit = [Word('t p1', key, key, 'word', band, unknown) for key, band, unknown in (('p', 4, False), ('q', 6, False), ('r', 7, True))]
        check([len(to_fix(unit, lv)) for lv in (1, 2, 3, 5, 6, 8, 12)] == [2, 2, 2, 1, 0, 1, 1], 'words to fix, hand-made words')
        check(best_level(unit, 3) == 5 and best_level(unit, 12) == 12, f'best offered: {best_level(unit, 3)}, {best_level(unit, 12)}')

        # --book narrows by title or label; --level sets the level the pages were read at
        evaluation, _ = evaluate(container, book_filters=('second',))
        check([label for label, _ in evaluation.pages] == ['B2 p1'], 'filter by title')
        evaluation, _ = evaluate(container, book_filters=('b1',))
        check(len(evaluation.pages) == 2, 'filter by label')
        evaluation, _ = evaluate(container, level=8)
        check(evaluation.level == 8 and Tally.of(evaluation.words, 8).unknown == 5, 'read at 8, murmur (band 5) was known')
        phone.close()

        # A level saved after the first correction is flagged
        late = make_database(root / 'late', scripts, (5, T + 15), [book_a], entries)
        evaluation, _ = evaluate(root / 'late')
        check(any('level was saved' in note for note in evaluation.notes), 'a level saved after corrections should be flagged')
        check(not any('level was saved' in note for note in evaluate(root / 'late', level=5)[0].notes), 'not with --level')
        late.close()

        # No profile: the app's default level, said so
        empty = make_database(root / 'noprofile', scripts, None, [book_b], [])
        evaluation, _ = evaluate(root / 'noprofile' / 'ReadStair.sqlite')
        check(evaluation.level == DEFAULT_LEVEL and 'no level saved' in evaluation.level_line, 'default level')
        check(any('No word on these pages has a state' in note for note in evaluation.notes), 'no corrections should be flagged')
        empty.close()

        # Only the main file copied: a clear error naming the -wal file, not an empty report
        lonely = root / 'lonely'
        lonely.mkdir()
        keep = make_database(root / 'walonly', scripts, (3, T), [book_a], entries)
        shutil.copyfile(root / 'walonly' / 'ReadStair.sqlite', lonely / 'ReadStair.sqlite')
        try:
            evaluate(lonely)
            check(False, 'a database without its -wal file should be refused')
        except EvalError as error:
            check('ReadStair.sqlite-wal is missing' in str(error), f'error: {error}')
        keep.close()

        # Two databases under one folder: ask which
        try:
            evaluate(root)
            check(False, 'several databases should be refused')
        except EvalError as error:
            check('expected one ReadStair.sqlite' in str(error), f'error: {error}')
    print(f'self-test passed: {checks} checks')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('path', nargs='?', type=Path, help='the downloaded .xcappdata, a folder inside it, or ReadStair.sqlite')
    parser.add_argument('--level', type=int, help='the level you read the pages at, if it was changed since (1-25)')
    parser.add_argument('--book', action='append', default=[], help='only books whose title contains this, or a label like B2')
    parser.add_argument('--self-test', action='store_true', help='check the script on a small database built with the app schema')
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parent.parent,
                        help='the ReadStair repository, for --self-test (default: the folder above this script)')
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test(args.repo)
            return 0
        if args.path is None:
            parser.error('give the downloaded container, a folder inside it, or ReadStair.sqlite')
        print(evaluate(args.path, args.level, tuple(args.book))[1], end='')
        return 0
    except (EvalError, sqlite3.Error, OSError) as error:
        # sqlite3.Error: a damaged or unexpected database; OSError: a file that cannot be read or copied
        print(f'book-eval: {error}', file=sys.stderr)
        return 1
    except SelfTestFailure as error:
        print(f'book-eval: self-test failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
