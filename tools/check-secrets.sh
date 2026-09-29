#!/usr/bin/env bash
# Pre-commit check: secrets, device IDs, computer paths, private terms and email addresses in staged files and their paths,
# forbidden file names, oversized files and non-English text; with --message (the commit-msg hook), the same checks on the
# commit message. With --staged (the pre-commit and pre-merge-commit hooks), a commit with no file to check passes; without it,
# nothing staged means every tracked file on disk is checked (by hand, and in CI). With --require-terms (release checks), a
# missing or empty private-terms list fails instead of skipping that check. A nonzero exit blocks the commit. A hit never
# prints what it caught, only where: a file, line numbers.
# Install the hook: git config core.hooksPath .githooks
set -u
require_terms=0
args=()
for a in "$@"; do if [ "$a" = --require-terms ]; then require_terms=1; else args+=("$a"); fi; done
set -- ${args[@]+"${args[@]}"}
# Bytes, not characters: under a UTF-8 locale tr stops at the first byte that is not valid UTF-8 (so a binary file would pass
# unread), and grep -i is slower. The CJK check decodes UTF-8 itself.
export LC_ALL=C

# Line numbers (at most 3) of CJK text in a file, or in standard input for -. BSD grep has no -P, so perl does the Unicode
# match; decoding per line instead of perl -C keeps one non-UTF-8 line from aborting the scan of the whole file.
cjk_lines() {
  perl -ne 'utf8::decode($_);
    if (/[\x{1100}-\x{11FF}\x{3000}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}\x{FF00}-\x{FFEF}]/) { push @n, $.; last if @n == 3 }
    END { print join(", ", @n) }' "$1" 2>/dev/null
}
# The first 3 distinct line numbers of grep -n output on standard input, as cjk_lines prints them; never the lines themselves
numbers() { awk -F: '!seen[$1]++ && ++n <= 3 { printf "%s%s", sep, $1; sep = ", " }'; }

# Secrets (OpenAI / GitHub / AWS / Google / Slack / private key blocks / Apple Team ID as xcconfig or Xcode's project
# file writes it), new-style device UDIDs, and computer paths (a home folder under /Users or /home, also with the slashes
# escaped as JSON may write them), an ECID or a serial number where it is named, matched ignoring case. Old-style UDIDs (40 hex) and UUIDs count only on a line about a
# device (simctl list marks its lines Booted or Shutdown; a Mac's Hardware UUID), or right after id= (as in an xcodebuild
# destination): elsewhere they are git hashes, checksums or package IDs.
id='([[:xdigit:]]{40}|[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12})([^[:xdigit:]]|$)'
device='(udid|device|simulator|simctl|destination|ecid|serial|booted|shutdown|hardware uuid)'
home='/(Users|home)\\?/[^/\\[:space:]]+'
serial='ecid[^[:alnum:]]{1,5}(0x)?[[:xdigit:]]{10,}|serial ?(number|no)( \([a-z]+\))?[^[:alnum:]]{1,5}[A-Z0-9]{10,12}([^[:alnum:]]|$)'
pattern="(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(DEVELOPMENT_TEAM|DevelopmentTeam)(\[[^]]*\])?\"? *= *\"?[A-Z0-9]{10}|[0-9]{8}-[0-9A-F]{16}|(^|[^[:alnum:]._~-])$home|$serial|$device.*[^[:xdigit:]]$id|(^|[^[:xdigit:]])$id.*$device|id=$id)"
# Lists kept in the git folder as info/NAME, so never committed and shared by worktrees: one entry per line. Lines starting
# with # are notes; spaces around an entry, Windows line ends and a byte order mark are dropped, so none of them hides an entry.
local_list() { perl -ne 's/^\xEF\xBB\xBF// if $. == 1; s/^\s+|\s+$//g; print "$_\n" if length && !/^#/' \
  "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/info/$1" 2>/dev/null; }
# Each line of standard input as an extended regular expression matching exactly that text
literal() { sed -e 's/[][\\.*^$+?(){}|/]/\\&/g'; }
# Email addresses: only placeholders pass (GitHub's noreply addresses, example.com/org/net)
email='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
allowed='@users\.noreply\.github\.com$|@example\.(com|org|net)$'
# Private terms (names, host names, device IDs): one per line in info/private-terms
terms=$(local_list private-terms)
private_lines() { [ -n "$terms" ] && grep -ainF -- "$terms" | numbers; }
if [ $require_terms = 1 ] && [ -z "$terms" ]; then
  echo "✗ No private terms: info/private-terms in the git folder is missing or empty, and --require-terms needs it"; exit 1
fi

# Commit-message mode (called by .githooks/commit-msg): the message is published too. Everything above the scissors line of
# commit -v is checked, # lines included, since git keeps them when the message comes from commit -m ("#42 Fix ..."), except
# git's list of files (# and a tab), which names deleted and untracked files too: a term there would block the very commit that
# removes it. Only the CJK and email checks skip every # line: git's own comments there may be localized and name the author.
if [ "${1:-}" = "--message" ]; then
  msg=$(sed -e '/^# -* >8 -*$/,$d' -e $'s/^#\t.*//' "$2")
  text=$(sed -e 's/^#.*//' <<< "$msg")
  # A message may also carry the committer's own address, public on every commit anyway (a release repository commits as
  # readstair.identity), and, outside a release repository, the addresses listed in info/allowed-emails in the git folder; each
  # is matched as a whole address (grep -no prints LINE:ADDRESS, so ':' anchors its start)
  role=$(git config --get readstair.role) me=$(git config user.email)
  [ "$role" != publish ] || me=$(git config --get readstair.identity | sed -n 's/.*<\(.*\)>$/\1/p')
  extra=$( { [ -z "$me" ] || echo "$me"; [ "$role" = publish ] || local_list allowed-emails; } | literal | sed 's/.*/|:&$/' | tr -d '\n')
  status=0
  check() { if [ -n "$2" ]; then echo "✗ $1 in the commit message, lines: $2"; status=1; fi; }
  check "Non-English (CJK) text" "$(cjk_lines - <<< "$text")"
  check "Possible secret, device ID or computer path" "$(grep -niE "$pattern" <<< "$msg" | numbers)"
  check "Private term" "$(private_lines <<< "$msg")"
  check "Possible email address" "$(grep -noE "$email" <<< "$text" | grep -viE "$allowed$extra" | numbers)"
  exit $status
fi

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"
# One path per line, unquoted (git otherwise quotes non-ASCII paths, which would then fail every lookup and skip all checks)
files=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMRT 2>/dev/null)
# How the checks read a file; with_content FILE COMMAND... runs COMMAND with the file's content as standard input.
if [ -n "$files" ]; then
  # A commit: check the staged content, which is what gets committed; the working copy may differ from it either way
  list='git diff --cached --name-only --diff-filter=ACMRT'
  exists() { git cat-file -e ":0:$1" 2>/dev/null; }
  with_content() { local f=$1; shift; git cat-file blob ":0:$f" | "$@"; }
  size_of() { git cat-file -s ":0:$1"; }
else
  # A commit with no file to check: a message-only amend, an empty commit, only deletions
  [ "${1:-}" = "--staged" ] && exit 0
  # Run by hand or in CI with nothing staged: scan every tracked file as it is on disk
  files=$(git -c core.quotePath=false ls-files)
  list='git ls-files'
  exists() { [ -f "$1" ]; }
  with_content() { local f=$1; shift; "$@" < "$f"; }
  size_of() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }
fi
# Images and PDFs count as binary even when grep -I would take their bytes for text
is_text() { case "$1" in *.png|*.jpg|*.jpeg|*.heic|*.pdf) return 1;; esac; with_content "$1" grep -Iq .; }
report() { echo "✗ $1: $label"; [ -z "${2:-}" ] || echo "  $2"; status=1; }
status=0

# a) File paths are published too: secrets, device IDs, computer paths and private terms in them, reported by entry number.
# Every other check names a flagged file by that number instead of its path.
by_pattern=$(grep -niE "$pattern" <<< "$files" | cut -d: -f1)
by_term=$([ -n "$terms" ] && grep -inF -- "$terms" <<< "$files" | cut -d: -f1)
if [ -n "$by_pattern" ]; then
  echo "✗ Possible secret, device ID or computer path in a file path, entries of $list: $(numbers <<< "$by_pattern")"; status=1
fi
if [ -n "$by_term" ]; then echo "✗ Private term in a file path, entries of $list: $(numbers <<< "$by_term")"; status=1; fi
# Git quotes a path holding a quote, backslash, tab or newline even with quotePath off, and no lookup finds it quoted
quoted=$(grep -n '^"' <<< "$files" | cut -d: -f1)
if [ -n "$quoted" ]; then
  echo "✗ File name with a quote, backslash, tab or newline, entries of $list: $(numbers <<< "$quoted")"; status=1
fi
flagged=" $(echo $by_pattern $by_term) "

i=0
while IFS= read -r f; do
  i=$((i + 1))
  case "$flagged" in *" $i "*) label="entry $i of $list";; *) label=$f;; esac

  # b) Forbidden file names
  case "$(basename "$f")" in
    *recovery*code*|*API_key*|*api_key*|*.p12|*.p8|*.pem|*.mobileprovision|.env|.env.*|*.db|*.sqlite|*.zip)
      echo "✗ Forbidden file: $label"; status=1;;
  esac
  exists "$f" || continue

  # c) Files over 5 MB
  size=$(size_of "$f")
  if [ "$size" -gt 5242880 ]; then echo "✗ File over 5 MB (publish it as a release asset instead): $label ($size bytes)"; status=1; fi

  if is_text "$f"; then
    # d) Text: secrets, device IDs, computer paths, private terms, email addresses, then CJK text (Chinese, Japanese kana,
    # Korean): the repository is English-only, and other languages belong in the localization resources, which are exempt.
    lines=$(with_content "$f" grep -naiE "$pattern" | numbers)
    [ -z "$lines" ] || report "Possible secret, device ID or computer path" "lines: $lines"
    lines=$(with_content "$f" private_lines)
    [ -z "$lines" ] || report "Private term" "lines: $lines"
    lines=$(with_content "$f" grep -naoE "$email" | grep -viE "$allowed" | numbers)
    [ -z "$lines" ] || report "Possible email address" "lines: $lines"
    case "$f" in *.xcstrings|*.strings|*.stringsdict|*.lproj/*) continue;; esac
    lines=$(with_content "$f" cjk_lines -)
    [ -z "$lines" ] || report "Non-English (CJK) text" "lines: $lines"
  else
    # e) Binary: computer paths, new-style device UDIDs and private terms in the text it holds. Dropping NUL bytes makes UTF-16
    # text (binary plists, some .strings files) searchable as ASCII; a path counts even run together with the bytes before it,
    # as binary strings are.
    with_content "$f" tr -d '\000' | grep -aqiE "$home|[0-9]{8}-[0-9a-f]{16}" && report "Computer path or device ID in a binary file"
    [ -n "$terms" ] || continue
    with_content "$f" tr -d '\000' | grep -aqiF -- "$terms" && report "Private term in a binary file"
  fi
done <<< "$files"

[ $status -eq 0 ] && echo "✓ No secrets, device IDs, computer paths, private terms, email addresses, forbidden or oversized files, or non-English text"
exit $status
