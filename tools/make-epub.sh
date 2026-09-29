#!/usr/bin/env bash
# Builds the repository's four EPUB files, each a minimal EPUB 3 (container.xml and a package document naming its title and
# language) zipped by Info-ZIP as EPUB readers expect: mimetype first and stored, the rest deflated. File times and modes are fixed,
# so the output is the same on every run.
# - Fixtures/alice-chapter-1.epub, for the core package's EPUB tests: Fixtures/source/alice-chapter-1.xhtml, unchanged.
# - App/ReadStair/SampleBook/alice.epub, the app's sample book: chapter I only, Fixtures/source/alice-chapter-1.xhtml unchanged,
#   with its author and the edition's cover, Fixtures/source/alice-cover.jpg. The later chapters would rate the app 13+ (a hookah,
#   wine, "Off with her head!"); ReadStair is rated 4+.
# - Fixtures/alice-whole.epub, for tests that need a long book: chapters I–XII, Fixtures/source/alice-chapter-1.xhtml and
#   Fixtures/sample/chapter-2.xhtml … chapter-12.xhtml, unchanged, with its author and a navigation document of Standard Ebooks'
#   12 chapter labels. Never in the app.
# - Fixtures/chapters.epub, for the table-of-contents tests: a title page outside the navigation document, chapter I, and a file
#   holding two entries, the second at a fragment mid-file.
# Every chapter is first checked against the sha256 of Standard Ebooks' file, and the cover against the one Fixtures/ATTRIBUTION.md
# gives; a mismatch stops the build.
# Usage (from anywhere in the repository): tools/make-epub.sh
set -euo pipefail
# Info-ZIP stores each file's Unix mode, which the umask would otherwise decide
umask 022

root="$(git rev-parse --show-toplevel)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

(cd "$root/Fixtures" && shasum -a 256 --quiet -c -) <<'EOF'
a006f6595337f1a3b35e46676352200514f1a50511125edda6bf898f83027486  source/alice-chapter-1.xhtml
8da2811b383d846ef601d2a8a1b48d151f88dbb707dcbc18991ce5af7222f4ac  sample/chapter-2.xhtml
2cc3e7f446b97a674961319697552d7ada2d48f23865c516c3e8038fb91ab42b  sample/chapter-3.xhtml
87174c0007490c8bde0991e97d77fb3334b8cfcb7b93a7b5912ad8e6d000a301  sample/chapter-4.xhtml
d2a6c805bf8cad6f5631f552b7390f4cd3ab5ef6a93551c49b04753231099471  sample/chapter-5.xhtml
e8d9376e33e57085b90a830f7aecacc6fae8eb1a439186d8c6cb9a1033c59934  sample/chapter-6.xhtml
0c88a01606bb2fa8447e7f01c3f311aea91853339ae14b9c5aa2b8c2b50ce1a7  sample/chapter-7.xhtml
6bd55fbfb1c392427d63693a0b2f9121a8edccd1cc1dbecc61843182e2919379  sample/chapter-8.xhtml
00ec54aa8e0a3ef1db3c84d05bf95b8d5030924552f78cbce65956ad89b021be  sample/chapter-9.xhtml
b7e15f3a02c8e99a911027a21e4f2501f62787d22194a09f52819315ee3c59ce  sample/chapter-10.xhtml
15c5479366bfe103062ea382a50237d7933b9762d6327c59c4f4a6da3201d9b3  sample/chapter-11.xhtml
d977322adcaf0e0cc2bfbe6dd1335df6699656fb456a4307c3fe48e37f9d0dbe  sample/chapter-12.xhtml
caf369a7ce0cc38dc4d7df99c5311d413ba74855c9eeb9f8d506d44c4ce27a19  source/alice-cover.jpg
EOF

# A new book folder under $work with what every book shares: mimetype, and container.xml naming OEBPS/content.opf
start() {
  mkdir -p "$work/$1/META-INF" "$work/$1/OEBPS/text"
  printf 'application/epub+zip' > "$work/$1/mimetype"
  cat > "$work/$1/META-INF/container.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
	<rootfiles>
		<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
	</rootfiles>
</container>
EOF
}

# pack FOLDER OUTPUT TIME FILE…: zips the book folder into OUTPUT (from the root), its files dated TIME (touch -t): mimetype,
# container.xml and the package document, then FILE… in that order
pack() {
  local folder="$work/$1" name="$2" time="$3"
  shift 3
  find "$folder" -exec touch -t "$time" {} +
  rm -f "$root/$name"
  (cd "$folder" && zip -q -X -0 "$root/$name" mimetype && zip -q -X -9 "$root/$name" META-INF/container.xml OEBPS/content.opf "$@")
  echo "✓ $name ($(wc -c < "$root/$name" | tr -d ' ') bytes)"
}

start alice-chapter-1
cat > "$work/alice-chapter-1/OEBPS/content.opf" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
	<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
		<dc:identifier id="uid">urn:uuid:f3c42b49-cada-494a-9620-9e2140c3b0f8</dc:identifier>
		<dc:title>Alice’s Adventures in Wonderland</dc:title>
		<dc:language>en-GB</dc:language>
		<meta property="dcterms:modified">2026-09-22T00:00:00Z</meta>
	</metadata>
	<manifest>
		<item id="chapter-1" href="text/chapter-1.xhtml" media-type="application/xhtml+xml"/>
	</manifest>
	<spine>
		<itemref idref="chapter-1"/>
	</spine>
</package>
EOF
cp "$root/Fixtures/source/alice-chapter-1.xhtml" "$work/alice-chapter-1/OEBPS/text/chapter-1.xhtml"
pack alice-chapter-1 Fixtures/alice-chapter-1.epub 202609220000 OEBPS/text/chapter-1.xhtml

start alice
cat > "$work/alice/OEBPS/content.opf" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
	<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
		<dc:identifier id="uid">urn:uuid:80539c37-5c97-4629-b17d-21840a6e50a0</dc:identifier>
		<dc:title>Alice’s Adventures in Wonderland</dc:title>
		<dc:creator>Lewis Carroll</dc:creator>
		<dc:language>en-GB</dc:language>
		<meta property="dcterms:modified">2026-09-27T00:00:00Z</meta>
	</metadata>
	<manifest>
		<item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
		<item id="chapter-1" href="text/chapter-1.xhtml" media-type="application/xhtml+xml"/>
	</manifest>
	<spine>
		<itemref idref="chapter-1"/>
	</spine>
</package>
EOF
cp "$root/Fixtures/source/alice-chapter-1.xhtml" "$work/alice/OEBPS/text/chapter-1.xhtml"
mkdir "$work/alice/OEBPS/images"
cp "$root/Fixtures/source/alice-cover.jpg" "$work/alice/OEBPS/images/cover.jpg"
pack alice App/ReadStair/SampleBook/alice.epub 202609270000 OEBPS/images/cover.jpg OEBPS/text/chapter-1.xhtml

start alice-whole
cat > "$work/alice-whole/OEBPS/content.opf" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
	<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
		<dc:identifier id="uid">urn:uuid:5d0f2a61-3b8e-4c47-9e1a-7c2f6a9b4e13</dc:identifier>
		<dc:title>Alice’s Adventures in Wonderland</dc:title>
		<dc:creator>Lewis Carroll</dc:creator>
		<dc:language>en-GB</dc:language>
		<meta property="dcterms:modified">2026-09-25T00:00:00Z</meta>
	</metadata>
	<manifest>
		<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
		<item id="chapter-1" href="text/chapter-1.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-2" href="text/chapter-2.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-3" href="text/chapter-3.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-4" href="text/chapter-4.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-5" href="text/chapter-5.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-6" href="text/chapter-6.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-7" href="text/chapter-7.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-8" href="text/chapter-8.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-9" href="text/chapter-9.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-10" href="text/chapter-10.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-11" href="text/chapter-11.xhtml" media-type="application/xhtml+xml"/>
		<item id="chapter-12" href="text/chapter-12.xhtml" media-type="application/xhtml+xml"/>
	</manifest>
	<spine>
		<itemref idref="chapter-1"/>
		<itemref idref="chapter-2"/>
		<itemref idref="chapter-3"/>
		<itemref idref="chapter-4"/>
		<itemref idref="chapter-5"/>
		<itemref idref="chapter-6"/>
		<itemref idref="chapter-7"/>
		<itemref idref="chapter-8"/>
		<itemref idref="chapter-9"/>
		<itemref idref="chapter-10"/>
		<itemref idref="chapter-11"/>
		<itemref idref="chapter-12"/>
	</spine>
</package>
EOF
cat > "$work/alice-whole/OEBPS/nav.xhtml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en-GB">
	<head>
		<title>Contents</title>
	</head>
	<body>
		<nav epub:type="toc">
			<ol>
				<li><a href="text/chapter-1.xhtml">I: Down the Rabbit-Hole</a></li>
				<li><a href="text/chapter-2.xhtml">II: The Pool of Tears</a></li>
				<li><a href="text/chapter-3.xhtml">III: A Caucus-Race and a Long Tale</a></li>
				<li><a href="text/chapter-4.xhtml">IV: The Rabbit Sends in a Little Bill</a></li>
				<li><a href="text/chapter-5.xhtml">V: Advice from a Caterpillar</a></li>
				<li><a href="text/chapter-6.xhtml">VI: Pig and Pepper</a></li>
				<li><a href="text/chapter-7.xhtml">VII: A Mad Tea-Party</a></li>
				<li><a href="text/chapter-8.xhtml">VIII: The Queen’s Croquet-Ground</a></li>
				<li><a href="text/chapter-9.xhtml">IX: The Mock Turtle’s Story</a></li>
				<li><a href="text/chapter-10.xhtml">X: The Lobster Quadrille</a></li>
				<li><a href="text/chapter-11.xhtml">XI: Who Stole the Tarts?</a></li>
				<li><a href="text/chapter-12.xhtml">XII: Alice’s Evidence</a></li>
			</ol>
		</nav>
	</body>
</html>
EOF
cp "$root/Fixtures/source/alice-chapter-1.xhtml" "$work/alice-whole/OEBPS/text/chapter-1.xhtml"
for n in 2 3 4 5 6 7 8 9 10 11 12; do cp "$root/Fixtures/sample/chapter-$n.xhtml" "$work/alice-whole/OEBPS/text/"; done
pack alice-whole Fixtures/alice-whole.epub 202609250000 OEBPS/nav.xhtml OEBPS/text/chapter-{1,2,3,4,5,6,7,8,9,10,11,12}.xhtml

start chapters
cat > "$work/chapters/OEBPS/content.opf" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
	<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
		<dc:identifier id="uid">urn:uuid:6681d0f9-0748-47c9-9658-b34b8f04aba8</dc:identifier>
		<dc:title>Three Chapters</dc:title>
		<dc:language>en</dc:language>
		<meta property="dcterms:modified">2026-09-25T00:00:00Z</meta>
	</metadata>
	<manifest>
		<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
		<item id="title" href="text/title.xhtml" media-type="application/xhtml+xml"/>
		<item id="a" href="text/a.xhtml" media-type="application/xhtml+xml"/>
		<item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"/>
	</manifest>
	<spine>
		<itemref idref="title"/>
		<itemref idref="a"/>
		<itemref idref="b"/>
	</spine>
</package>
EOF
cat > "$work/chapters/OEBPS/nav.xhtml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
	<head>
		<title>Contents</title>
	</head>
	<body>
		<nav epub:type="toc">
			<ol>
				<li><a href="text/a.xhtml">I: Down the Rabbit-Hole</a></li>
				<li><a href="text/b.xhtml#two">Two</a></li>
				<li><a href="text/b.xhtml#three">Three: A Chapter Whose Title Is Long Enough to Wrap onto Two Lines on All Phones</a></li>
			</ol>
		</nav>
	</body>
</html>
EOF
cat > "$work/chapters/OEBPS/text/title.xhtml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
	<head>
		<title>Three Chapters</title>
	</head>
	<body>
		<h1>Three Chapters</h1>
		<p>A test book dedicated to the public domain.</p>
	</body>
</html>
EOF
cp "$root/Fixtures/source/alice-chapter-1.xhtml" "$work/chapters/OEBPS/text/a.xhtml"
cat > "$work/chapters/OEBPS/text/b.xhtml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
	<head>
		<title>Two and Three</title>
	</head>
	<body>
		<section id="two">
			<h2>Two</h2>
			<p>One short paragraph.</p>
		</section>
		<section id="three">
			<h2>Three: A Chapter Whose Title Is Long Enough to Wrap onto Two Lines on All Phones</h2>
			<p>One short paragraph.</p>
		</section>
	</body>
</html>
EOF
pack chapters Fixtures/chapters.epub 202609250000 OEBPS/nav.xhtml OEBPS/text/title.xhtml OEBPS/text/a.xhtml OEBPS/text/b.xhtml
