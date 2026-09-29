#!/bin/bash
# Maintainers only: the release test, run inside an export (never in the development repository), and the offline guard check.
#   release-gate.sh --guards DEV_REPO [RELEASE_REPO]
#       proves offline that the development repository (and the notes repository nested in it as docs/) can push only to
#       their private backup, that the push hooks are installed, and that the release repository's settings and push hook hold
#   release-gate.sh next|minor|major OUT --dev DEV_REPO [--short FULL_RECORD] [--core REGEX] [--ui TEST...]
#       minor and major: the full test (G0-G7); --short, for a re-upload whose only change is the build number, runs G0, G1,
#       the core tests and G3 and cites FULL_RECORD. next: G0, G1's content checks, the core tests matching --core, the UI
#       tests named by --ui (ReadStairUITests/Class[/testMethod]) and G3. Logs and OUT/record.md go to OUT, a new folder
#       outside the export.
# One simulator is booted at a time. Nothing here reaches the network.
set -uo pipefail
export LC_ALL=C DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
public_url='https://github.com/OAK-WJR/readstair.git'
at=@   # built up, so the privacy check does not read ssh URLs as email addresses
ios=26.5
# UI tests that may fail once for reasons outside the app; a failure counts as flaky only if it is listed here AND passes alone
known_flaky='testUI_A11Y_001_books testUI_GRID_001_cells testP_LAUNCH_001_coldLaunchToShelf testUI_BOOK_001_chaptersAndBack'
# Classes also run at the largest accessibility text size (GridTests goes through the sizes itself)
ax5_classes='ImportTests OpenFileTests SettingsTests ShelfTests BookPageTests'
# People an EPUB in the repository may name as creator or contributor
allowed_people='Lewis Carroll'
problems=0
note() { echo "$*" | tee -a "$out/status.txt"; }
bad() { note "FAIL $*"; problems=$((problems + 1)); }
good() { note "PASS $*"; }
die() { echo "release-gate: $*" >&2; exit 2; }
# A command with a hard time limit that kills its whole process group (a deadlocked test runner ignores its own limits)
limit() { perl -e 'my $s = shift; my $pid = fork // die; if (!$pid) { setpgrp(0, 0); open STDIN, "<", "/dev/null"; exec @ARGV or die }
  $SIG{ALRM} = sub { print STDERR "timed out after $s s\n"; kill "TERM", -$pid; sleep 10; kill "KILL", -$pid; exit 124 };
  alarm $s; waitpid $pid, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"; }
# Booting simulators can send the load average to several hundred for minutes; UI tests started then fail on timing
calm() { local i; for i in $(seq 1 360); do sysctl -n vm.loadavg | awk '{exit !($2 < 40 && $3 < 40)}' && return 0; sleep 10; done; }
# The UDID of the iOS $ios simulator with this exact name (optionally followed by a version, "iPhone SE (3rd generation) 26.5")
simulator() {
  local name; name=$(sed 's/[][().*+?^$|{}\\]/\\&/g' <<< "$1")
  xcrun simctl list devices available | awk -v rt="-- iOS $ios --" '/^-- /{on = ($0 == rt)} on' \
    | grep -E "^    $name( [0-9.]+)? \([0-9A-F-]{36}\)" | head -1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}'
}

# ---------------------------------------------------------------------------------------------------------------- guards
guards() {
  local dev=$1 release=${2:-} tmp repo url u fails=0 hooks z=0000000000000000000000000000000000000000
  check() { if [ "$1" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3 (got '$2')"; fails=$((fails + 1)); fi; }
  tmp=$(mktemp -d)
  printf '#!/bin/bash\necho "${FAKE_VISIBILITY:-PRIVATE}"\n' > "$tmp/gh"; chmod +x "$tmp/gh"
  hooks=$(cd "$dev/.githooks" && pwd -P)
  for repo in "$dev" "$dev/docs"; do
    if [ ! -e "$repo/.git" ]; then echo "FAIL $repo is not a git repository"; fails=$((fails + 1)); continue; fi
    url=$(git -C "$repo" config --get readstair.backupUrl) || url=
    check private "$(git -C "$repo" config --get readstair.role)" "$repo: role private"
    case "$url" in https://github.com/OAK-WJR/*.git) [ "$url" != "$public_url" ] && check ok ok "$repo: backup URL" || check ok "$url" "$repo: backup URL";;
      *) check ok "$url" "$repo: backup URL";; esac
    check "$url" "$(git -C "$repo" remote get-url --push backup 2>/dev/null)" "$repo: remote backup is exactly that URL"
    check backup "$(git -C "$repo" remote | tr '\n' ' ' | sed 's/ $//')" "$repo: backup is the only remote"
    if [ "$repo" = "$dev/docs" ]; then
      check "$(git -C "$dev" config --get readstair.backupUrl)" "$url" "$repo: the same backup as the code"
      check refs/heads/main:refs/heads/docs "$(git -C "$repo" config --get-all remote.backup.push)" "$repo: pushes only to the branch docs"
    else
      check absent "$(git -C "$repo" show-ref -q --verify refs/heads/docs && echo present || echo absent)" "$repo: no branch named docs (that name holds docs/)"
    fi
    # the push hook in effect must be this repository's .githooks/pre-push (docs/ links to it and has no commit hooks)
    check "$hooks/pre-push" "$(cd "$repo" && perl -MCwd -e 'print Cwd::abs_path(shift)' "$(git rev-parse --git-path hooks)/pre-push" 2>/dev/null)" "$repo: push hook installed"
    check never "$(git -C "$repo" config --get protocol.ssh.allow)" "$repo: ssh transport off"
    check "$url" "$(git -C "$repo" ls-remote --get-url "$url")" "$repo: backup URL not rewritten"
    for u in "$public_url" "git${at}github.com:OAK-WJR/readstair.git" "ssh://git${at}github.com/OAK-WJR/readstair.git" https://github.com/OAK-WJR/readstair; do
      case "$(git -C "$repo" ls-remote --get-url "$u")" in never-push::*) check ok ok "$repo: $u rewritten";; *) check ok bad "$repo: $u rewritten";; esac
    done
    # credentials are counted, never printed: exactly one for the backup, none for any spelling of the public repository
    creds() { printf 'url=%s\n\n' "$1" | GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false git -C "$repo" credential fill 2>/dev/null | grep -c '^password='; }
    check 1 "$(creds "$url")" "$repo: one credential for the backup"
    for u in "$public_url" https://GitHub.com/OAK-WJR/readstair.git "https://OAK-WJR${at}github.com/OAK-WJR/readstair.git" https://github.com:443/OAK-WJR/readstair.git https://www.github.com/OAK-WJR/readstair.git; do
      check 0 "$(creds "$u")" "$repo: no credential for $u"
    done
    check 0 "$(cd "$repo" && PATH="$tmp:$PATH" FAKE_VISIBILITY=PRIVATE "$hooks/pre-push" backup "$url" < /dev/null > /dev/null 2>&1; echo $?)" "$repo: hook lets the private backup through"
    check 1 "$(cd "$repo" && PATH="$tmp:$PATH" FAKE_VISIBILITY=PUBLIC "$hooks/pre-push" backup "$url" < /dev/null > /dev/null 2>&1; echo $?)" "$repo: hook refuses a backup GitHub reports public"
    check 1 "$(cd "$repo" && echo "refs/heads/x $z refs/heads/x $(git rev-parse HEAD)" | PATH="$tmp:$PATH" FAKE_VISIBILITY=PRIVATE "$hooks/pre-push" backup "$url" > /dev/null 2>&1; echo $?)" "$repo: hook refuses a deletion in the backup"
    check 1 "$(cd "$repo" && echo "refs/heads/x $(git rev-parse HEAD~1) refs/heads/x $(git rev-parse HEAD)" | PATH="$tmp:$PATH" FAKE_VISIBILITY=PRIVATE "$hooks/pre-push" backup "$url" > /dev/null 2>&1; echo $?)" "$repo: hook refuses a rewrite in the backup"
    check 1 "$(cd "$repo" && PATH="$tmp:$PATH" "$hooks/pre-push" x "$public_url" < /dev/null > /dev/null 2>&1; echo $?)" "$repo: hook refuses the public repository"
  done
  if [ -n "$release" ]; then
    check publish "$(git -C "$release" config --get readstair.role)" "release repository: role publish"
    check origin "$(git -C "$release" remote | tr '\n' ' ' | sed 's/ $//')" "release repository: origin is the only remote"
    check "$public_url" "$(git -C "$release" remote get-url --push origin)" "release repository: pushes to $public_url"
    check refs/heads/main:refs/heads/main "$(git -C "$release" config --get-all remote.origin.push)" "release repository: pushes only main"
    check .githooks "$(git -C "$release" config --get core.hooksPath)" "release repository: hooks on"
    check "" "$(git -C "$release" config --get readstair.publicUrl)" "release repository: no stand-in URL"
    git -C "$release" config --get readstair.identity > /dev/null && check ok ok "release repository: identity set" || check ok missing "release repository: identity set"
  fi
  # The release hook, fed by hand in a scratch repository: only the approved single commit to the public URL passes, and its
  # version tag as export-release.sh --approve makes it
  local c d g m r=0 t=0 who='P <p@example.com>'
  (cd "$tmp" && git init -q -b main rel && cd rel && git config readstair.role publish && git config readstair.publicUrl "$tmp/bare.git" \
    && git config readstair.identity "$who" \
    && git -c user.name=R -c user.email=r@example.com commit -q --allow-empty -m 'ReadStair 1.0.0 (build 1)' \
    && git -c user.name=R -c user.email=r@example.com commit -q --allow-empty -m 'ReadStair 1.1.0 (build 2)') || r=1
  c=$(git -C "$tmp/rel" rev-parse HEAD~1) d=$(git -C "$tmp/rel" rev-parse HEAD)
  feed() { local u=$1; shift; (cd "$tmp/rel" && printf '%s\n' "$@" | "$hooks/pre-push" origin "$u" > /dev/null 2>&1); }
  if feed "$tmp/bare.git" "refs/heads/main $c refs/heads/main $z"; then r=1; fi                       # not approved
  git -C "$tmp/rel" config readstair.approvedCommit "$c"
  feed "$tmp/bare.git" "refs/heads/main $c refs/heads/main $z" || r=1                               # the approved first commit
  if feed "$public_url" "refs/heads/main $c refs/heads/main $z"; then r=1; fi                          # another URL
  if feed "$tmp/bare.git" "refs/heads/main $z refs/heads/main $c"; then r=1; fi                        # deleting main
  # tags: one made as --approve makes it, and by hand (mk COMMIT NAME TAGGER [ZONE]) ones that differ from it in one thing each
  g=$(printf 'object %s\ntype commit\ntag v1.0.0\ntagger %s %s\n\nReadStair 1.0.0\n' "$c" "$who" "$(date +%s) $(TZ=America/Los_Angeles date +%z)" \
    | git -C "$tmp/rel" mktag) || t=1
  m="refs/heads/main $c refs/heads/main $z"
  mk() { printf 'object %s\ntype commit\ntag %s\ntagger %s 1700000000 %s\n\nReadStair %s\n' "$1" "$2" "$3" "${4:--0800}" "${2#v}" | git -C "$tmp/rel" mktag; }
  feed "$tmp/bare.git" "refs/tags/v1.0.0 $g refs/tags/v1.0.0 $z" "$m" || t=1                                   # the tag, then main
  feed "$tmp/bare.git" "refs/tags/v1.0.0 $(mk "$c" v1.0.0 "$who") refs/tags/v1.0.0 $z" "$m" || t=1            # the same by hand
  feed "$tmp/bare.git" "refs/tags/v1.0.0 $(mk "$c" v1.0.0 "$who" -0700) refs/tags/v1.0.0 $z" "$m" || t=1      # zone -0700
  if feed "$tmp/bare.git" "refs/tags/v1.0.0 $c refs/tags/v1.0.0 $z" "$m"; then t=1; fi                        # lightweight
  if feed "$tmp/bare.git" "refs/tags/v1.0.1 $(mk "$c" v1.0.1 "$who") refs/tags/v1.0.1 $z" "$m"; then t=1; fi  # wrong version
  if feed "$tmp/bare.git" "refs/tags/v1.0.0 $(mk "$d" v1.0.0 "$who") refs/tags/v1.0.0 $z" "$m"; then t=1; fi  # another commit
  if feed "$tmp/bare.git" "refs/tags/v1.0.0 $(mk "$c" v1.0.0 'R <r@example.com>') refs/tags/v1.0.0 $z" "$m"; then t=1; fi # another tagger
  if feed "$tmp/bare.git" "refs/tags/v1.0.0 $(mk "$c" v1.0.0 "$who" +0000) refs/tags/v1.0.0 $z" "$m"; then t=1; fi  # zone +0000
  if feed "$tmp/bare.git" "refs/tags/v1.0.0 $(mk "$c" v1.0.0 "$who" +0800) refs/tags/v1.0.0 $z" "$m"; then t=1; fi  # zone +0800
  if feed "$tmp/bare.git" "refs/tags/v1.0.0 $g refs/tags/v1.0.0 $d" "$m"; then t=1; fi                        # already on GitHub
  if feed "$tmp/bare.git" "refs/tags/v1.0.0 $z refs/tags/v1.0.0 $g" "$m"; then t=1; fi                        # deleting it
  if feed "$tmp/bare.git" "refs/tags/v1 $g refs/tags/v1 $z" "$m"; then t=1; fi                                # another name
  check 0 $t "release hook: only the approved commit's version tag, as --approve makes it, passes"
  git -C "$tmp/rel" config readstair.approvedCommit "$d"
  if feed "$tmp/bare.git" "refs/heads/main $d refs/heads/main $z"; then r=1; fi                        # two commits at once
  feed "$tmp/bare.git" "refs/heads/main $d refs/heads/main $c" || r=1                               # one approved commit on top
  check 0 $r "release hook: only the approved single commit to the public repository passes"
  rm -rf "$tmp"
  [ $fails = 0 ] && echo "Guards: PASS" || echo "Guards: FAIL ($fails)"
  return $fails
}

if [ "${1:-}" = --guards ]; then
  [ $# -ge 2 ] || die "usage: --guards DEV_REPO [RELEASE_REPO]"
  guards "$2" "${3:-}"; exit $?
fi

# ---------------------------------------------------------------------------------------------------------------- gate
command=${1:-}; out=${2:-}
case "$command" in next|minor|major) ;; *) die "usage: next|minor|major OUT --dev DEV_REPO [--short FULL_RECORD] [--core REGEX] [--ui TEST...]";; esac
shift 2
dev= full= core= ui=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) dev=$2; shift 2;;
    --short) full=$2; shift 2;;
    --core) core=$2; shift 2;;
    --ui) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do ui+=("$1"); shift; done;;
    *) die "unknown argument $1";;
  esac
done
[ -n "$dev" ] && [ -d "$dev/.git" ] || die "--dev must name the development repository"
dev=$(cd "$dev" && pwd -P)
export_dir=$(git rev-parse --show-toplevel) || die "run this inside the export"
export_dir=$(cd "$export_dir" && pwd -P)
[ "$export_dir" != "$dev" ] || die "this is the development repository; run the release test in the export"
[ -n "$out" ] && [ ! -e "$out" ] || die "OUT must be a new folder"
mkdir -p "$out/ui" || die "cannot make $out"
out=$(cd "$out" && pwd -P)
case "$out/" in "$export_dir"/*) die "OUT must be outside the export";; esac
cd "$export_dir"
role=$(git config --get readstair.role || true)
[ "$command" = major ] && [ "$role" != publish ] && die "major runs in the release repository"
[ "$command" != major ] && [ "$role" = publish ] && die "next and minor run in a worktree, not the release repository"
[ "$command" = next ] && [ -n "$full" ] && die "--short is for minor and major"
[ "$command" != next ] && { [ -n "$core" ] || [ ${#ui[@]} -gt 0 ]; } && die "--core and --ui are for next"
[ "$command" = next ] && [ -z "$core" ] && [ ${#ui[@]} = 0 ] && die "next needs --core or --ui: the tests of what changed"
version=$(sed -n 's/^MARKETING_VERSION = //p' Config/Shared.xcconfig)
build=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' Config/Shared.xcconfig)
dd=$export_dir/build/gate-dd perf_store=$export_dir/build/perf-store
pro=$(simulator 'iPhone 17 Pro'); se=$(simulator 'iPhone SE (3rd generation)'); ipad=$(simulator 'iPad (A16)')
[ -n "$pro" ] || die "no iPhone 17 Pro simulator with iOS $ios"
caffeinate -dimsu -w $$ &
start=$(date +%s)
note "START $command $version (build $build) $(date '+%F %T'), iOS $ios simulators"

# G0 preflight
note "== G0"
calm
xcrun simctl shutdown all 2>/dev/null
t0=$(git rev-parse 'HEAD^{tree}')
rel=$(git -C "$dev" rev-parse -q --verify "refs/tags/release/$version-b$build^{commit}") || { bad "no tag release/$version-b$build in the development repository"; rel=; }
[ -n "$rel" ] && { [ "$(git -C "$dev" rev-parse "$rel^{tree}")" = "$t0" ] && good "tree $t0 is REL's" || bad "tree is not REL's"; }
previous=$( [ -n "$rel" ] && git -C "$dev" tag -l 'release/*' --sort=-creatordate --no-contains "$rel" | head -1 )
[ -z "$(git status --porcelain)" ] && good "no changes" || bad "the export has changes"
allow='^!! (build/|Packages/ReadStairCore/\.build/|Packages/ReadStairCore/\.swiftpm/|(.*/)?\.DS_Store|(.*/)?xcuserdata/)$'
ignored() { git status --porcelain --ignored | grep '^!! ' | grep -vE "$allow" || true; }
[ -z "$(ignored)" ] && good "ignored files within the allowlist" || bad "ignored files outside the allowlist: $(ignored | tr '\n' ' ')"
[ ! -e Config/Local.xcconfig ] && good "no Local.xcconfig" || bad "Config/Local.xcconfig is present"
if [ "$role" = publish ]; then guards "$dev" "$export_dir" > "$out/guards.txt" 2>&1; else guards "$dev" > "$out/guards.txt" 2>&1; fi \
  && good "guards" || bad "guards (see guards.txt)"
if [ -n "$full" ]; then # --short: the only change since the fully tested REL is the build number
  fullrel=$(sed -n 's/^REL: //p' "$full" | head -1)
  grep -qx 'Scope: full' "$full" && grep -qx 'Verdict: PASS' "$full" && [ -n "$fullrel" ] || bad "--short needs a full, passed record"
  changed=$(git -C "$dev" diff -U0 "$fullrel" "$rel" 2>/dev/null | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+]CURRENT_PROJECT_VERSION = [0-9]+$' || true)
  files=$(git -C "$dev" diff --name-only "$fullrel" "$rel" 2>/dev/null)
  [ "$files" = Config/Shared.xcconfig ] && [ -z "$changed" ] && good "only the build number changed since $(basename "$full")" \
    || bad "--short: more than the build number changed since the full test"
fi
rm -rf "$dd"
for u in "$pro" ${se:+"$se"}; do xcrun simctl erase "$u" 2>/dev/null; done

# G1 content checks, and for major the publication checks
note "== G1"
tools/check-secrets.sh --require-terms > "$out/secrets.txt" 2>&1 && good "privacy scan" || bad "privacy scan (see secrets.txt)"
tmp=$(mktemp -d)
media=$(git ls-files '*.png' '*.jpg' '*.jpeg' '*.heic' '*.gif' '*.webp' | sed "s|^|$export_dir/|")
for e in $(git ls-files '*.epub'); do
  mkdir -p "$tmp/$e" && unzip -q -o "$e" -d "$tmp/$e" || { bad "cannot unpack $e"; continue; }
  media+=$'\n'$(find "$tmp/$e" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' \))
  opf=$(sed -n 's/.*full-path="\([^"]*\)".*/\1/p' "$tmp/$e/META-INF/container.xml" 2>/dev/null | head -1)
  [ -n "$opf" ] && [ -f "$tmp/$e/$opf" ] || { bad "$e has no readable package document"; continue; }
  people=$(grep -oE '<dc:(creator|contributor)[^>]*>[^<]*' "$tmp/$e/$opf" | sed 's/.*>//' | sort -u)
  while IFS= read -r p; do [ -z "$p" ] || grep -qxF "$p" <<< "$allowed_people" || bad "$e names '$p', who is not on the allowlist"; done <<< "$people"
done
[ -z "$(git ls-files '*.pdf')" ] || bad "PDFs are tracked; add their metadata check first"
cat > "$tmp/metadata.swift" <<'SWIFT'
import Foundation
import ImageIO
// Prints "path: group key" for metadata that could identify a person, a place or a device
let flagged: [CFString: [CFString]] = [
  kCGImagePropertyGPSDictionary: [],
  kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
                                    kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFHostComputer],
  kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName,
                                    kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel],
  kCGImagePropertyExifAuxDictionary: [kCGImagePropertyExifAuxSerialNumber, kCGImagePropertyExifAuxOwnerName],
  kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline, kCGImagePropertyIPTCCreatorContactInfo, kCGImagePropertyIPTCCredit],
  kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor, kCGImagePropertyPNGSoftware, kCGImagePropertyPNGComment],
]
while let path = readLine() {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { print("\(path): unreadable"); continue }
  for i in 0..<CGImageSourceGetCount(source) {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] ?? [:]
    for (group, keys) in flagged {
      guard let dictionary = properties[group] as? [CFString: Any] else { continue }
      for key in dictionary.keys where keys.isEmpty || keys.contains(key) { print("\(path): \(group) \(key)") }
    }
  }
}
SWIFT
tagged=$(grep -v '^$' <<< "$media" | swift "$tmp/metadata.swift" 2>/dev/null) || bad "the image metadata check did not run"
[ -z "$tagged" ] && good "no identifying metadata in $(grep -c . <<< "$media") images" || bad "identifying metadata: $(sed "s|$export_dir/||; s|$tmp/||" <<< "$tagged" | tr '\n' ' ')"
rm -rf "$tmp"
if [ "$role" = publish ]; then
  [ -z "$(git ls-files | grep -E '^docs/|^Config/Local\.xcconfig$' || true)" ] && good "no private folders tracked" || bad "docs/ or Local.xcconfig is tracked"
  # Nor anything the development repository keeps out of git by its local exclude file, which must hold at least one pattern
  exclude="$(git -C "$dev" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  if grep -qv -e '^#' -e '^[[:space:]]*$' "$exclude" 2>/dev/null; then
    local_only=$(git ls-files -ci --exclude-from="$exclude") || local_only='(git ls-files failed)'
    [ -z "$local_only" ] && good "nothing tracked that info/exclude keeps local" || bad "tracked, though info/exclude keeps it local: $(head -3 <<< "$local_only" | tr '\n' ' ')"
  else
    bad "the development repository's info/exclude has no pattern"
  fi
  # Everything published is English, localization resources included (the privacy scan exempts those)
  cjk=$(git ls-files -z | xargs -0 perl -ne 'utf8::decode($_); if (/[\x{1100}-\x{11FF}\x{3000}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}\x{FF00}-\x{FFEF}]/ && -T $ARGV) { print "$ARGV\n"; close ARGV }' 2>/dev/null | sort -u)
  [ -z "$cjk" ] && good "every published file is English" || bad "CJK text in: $(tr '\n' ' ' <<< "$cjk")"
  if command -v gitleaks > /dev/null; then
    offline='(version 1)(allow default)(deny network*)'
    sandbox-exec -p "$offline" gitleaks git --no-banner --redact . > "$out/gitleaks-git.txt" 2>&1 && good "gitleaks history" || bad "gitleaks history (see gitleaks-git.txt)"
    sandbox-exec -p "$offline" gitleaks dir --no-banner --redact . > "$out/gitleaks-dir.txt" 2>&1 && good "gitleaks files" || bad "gitleaks files (see gitleaks-dir.txt)"
  else
    bad "gitleaks is not installed (install it for the release test, remove it after)"
  fi
fi

# G2 core
note "== G2"
spm() { local name=$1; shift; (cd Packages/ReadStairCore && limit 3600 env "$@" > "$out/$name.log" 2>&1); }
if [ "$command" = next ]; then
  if [ -n "$core" ]; then
    spm core swift test --filter "$core"; c=$?
    n=$(grep -oE 'Test run with [0-9]+ test' "$out/core.log" | tail -1 | grep -oE '[0-9]+' || echo 0)
    [ $c = 0 ] && [ "${n:-0}" -gt 0 ] && good "$n core tests matching $core" || bad "core tests matching $core (exit $c, ${n:-0} tests ran)"
  fi
else
  spm core swift test && good "core: $(grep -o 'Test run with [0-9]* tests' "$out/core.log" | tail -1)" || bad "core tests (see core.log)"
  if [ -z "$full" ]; then
    spm replay READSTAIR_EXPERIMENT=1 swift test --filter SyntheticReaderReplay && good "replay gates" || bad "replay gates (see replay.log)"
    python3 tools/make-lexicon.py --check > "$out/lexicon.log" 2>&1 && good "lexicon rebuilds byte for byte" || bad "lexicon check (see lexicon.log)"
    python3 tools/book-eval.py --self-test > "$out/book-eval.log" 2>&1 && good "book-eval self-test" || bad "book-eval self-test"
    rm -rf "$perf_store"
    spm perfstore READSTAIR_PERF_STORE="$perf_store" swift test --filter PerfStoreFixture && good "performance store" || bad "performance store (see perfstore.log)"
  fi
fi

# G3 builds, 0 Swift warnings each
note "== G3"
xb() { local name=$1; shift; limit 5400 xcodebuild "$@" > "$out/build-$name.log" 2>&1; local c=$?
  local w; w=$(grep -cE '\.swift:[0-9]+:[0-9]+: warning' "$out/build-$name.log")
  [ $c = 0 ] && [ "$w" = 0 ] && good "build $name" || bad "build $name (exit $c, $w Swift warnings)"; }
xb test-debug build-for-testing -project App/ReadStair.xcodeproj -scheme ReadStair -destination "platform=iOS Simulator,id=$pro" -derivedDataPath "$dd"
xb release build -project App/ReadStair.xcodeproj -scheme ReadStair -sdk iphonesimulator -configuration Release -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO
for cfg in Debug Release; do
  xb "$cfg-icloud" build -project App/ReadStair.xcodeproj -scheme ReadStair -sdk iphonesimulator -configuration $cfg -derivedDataPath "$dd-icloud" READSTAIR_ICLOUD=YES CODE_SIGNING_ALLOWED=NO
done
tools/check-package.sh --app "$dd/Build/Products/Release-iphonesimulator/ReadStair.app" "$export_dir" > "$out/package-sim.txt" 2>&1 && good "simulator Release package checks" || bad "simulator Release package checks (see package-sim.txt)"
xctestrun=$(ls "$dd"/Build/Products/*.xctestrun 2>/dev/null | head -1)

# UI cells: one xcodebuild run each, retried once only if the test runner never started
boot() { xcrun simctl boot "$1" 2>/dev/null; limit 600 xcrun simctl bootstatus "$1" -b > /dev/null || bad "simulator $1 did not boot"; calm; }
failures=()
cell() { # cell NAME UDID APPEARANCE SIZE ONLY-TESTING...; returns 0 only when every selected test ran and passed
  local name=$1 udid=$2 appearance=$3 size=$4; shift 4
  local simsize=large; [ "$size" = AX5 ] && simsize=accessibility-extra-extra-extra-large
  xcrun simctl ui "$udid" appearance "$appearance"; xcrun simctl ui "$udid" content_size "$simsize"
  local attempt log code failed listed started ended
  for attempt in 1 2; do
    log=$out/ui/$name-a$attempt.log; rm -rf "$out/ui/$name-a$attempt.xcresult"
    TEST_RUNNER_READSTAIR_APPEARANCE=$appearance TEST_RUNNER_READSTAIR_CONTENT_SIZE=$size limit 3600 xcodebuild test-without-building \
      -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$udid" -resultBundlePath "$out/ui/$name-a$attempt.xcresult" "$@" > "$log" 2>&1
    code=$?
    grep -qiE 'timed out while (loading|initializing)|Test runner never began executing|failed to initialize for UI testing' "$log" || break
  done
  last_log=$log
  if [ $code = 124 ]; then xcrun simctl shutdown "$udid" 2>/dev/null; boot "$udid"; fi   # a killed run can leave the runner inside
  xcrun simctl ui "$udid" appearance light; xcrun simctl ui "$udid" content_size large
  failed=$(grep -oE "Test Case '-\[ReadStairUITests\.[A-Za-z]+ [A-Za-z0-9_]+\]' failed" "$log" | sed -E 's/.*\.([A-Za-z]+) ([A-Za-z0-9_]+)\].*/\1\/\2/' | sort -u)
  # A finished run: xcodebuild's own list of failing tests is exactly those, every test that started also ended, and the
  # runner reached its own end line
  listed=$(awk '/^Failing tests:$/ {f = 1; next} f && /^\t/ {sub(/^\t/, ""); sub(/\(\)$/, ""); sub(/\./, "/"); print; next} {f = 0}' "$log" | sort -u)
  started=$(grep -cE "^Test Case '.*' started\.$" "$log") ended=$(grep -cE "^Test Case '.*' (passed|failed|skipped) " "$log")
  if [ $code = 0 ]; then good "UI $name"; return 0; fi
  # test-without-building ends with ** TEST EXECUTE FAILED **, a plain test run with ** TEST FAILED **
  if [ $code = 65 ] && grep -qE '\*\* TEST (EXECUTE )?FAILED \*\*' "$log" && [ -n "$failed" ] && [ "$listed" = "$failed" ] \
    && [ "$started" = "$ended" ] && grep -qE "^Test Suite 'Selected tests' (passed|failed) at " "$log"; then
    note "UI $name failed: $(tr '\n' ' ' <<< "$failed")"
    while IFS= read -r t; do failures+=("$name|$udid|$appearance|$size|$t"); done <<< "$failed"
  else
    bad "UI $name did not finish (exit $code; see ui/$name-a$attempt.log)"
  fi
  return 1
}
classes=$(grep -h -oE 'final class [A-Za-z]+Tests: UITestCase' App/ReadStairUITests/*.swift | awk '{print $3}' | tr -d ':' | sort)
device() { # device LABEL UDID: every class at the default size, the AX5 classes, the audits in dark
  local label=$1 udid=$2 c
  boot "$udid"
  for c in $classes; do [ $c = PerformanceGateTests ] || cell "default-$label-$c" "$udid" light default "-only-testing:ReadStairUITests/$c"; done
  for c in $ax5_classes; do
    local extra=(); [ $c = ShelfTests ] && extra=(-skip-testing:ReadStairUITests/ShelfTests/testUI_SHELF_003_sampleBook)
    cell "AX5-$label-$c" "$udid" light AX5 "-only-testing:ReadStairUITests/$c" ${extra[@]+"${extra[@]}"}
  done
  cell "dark-$label-AccessibilityTests" "$udid" dark default -only-testing:ReadStairUITests/AccessibilityTests
}

if [ "$command" = next ]; then
  if [ ${#ui[@]} -gt 0 ]; then
    note "== UI (next: the new and changed features)"
    boot "$pro"; args=(); for t in "${ui[@]}"; do args+=("-only-testing:$t"); done
    cell "next-17Pro" "$pro" light default "${args[@]}"
    last=$last_log
    executed=$(grep -hoE 'Executed [0-9]+ tests?' "$last" | tail -1 | grep -oE '[0-9]+' || echo 0)
    skipped=$(grep -hoE '[0-9]+ tests? skipped' "$last" | tail -1 | grep -oE '[0-9]+' || echo 0)
    ran=$(( ${executed:-0} - ${skipped:-0} ))
    [ $ran -gt 0 ] && good "$ran UI tests ran" || bad "no UI test ran (check the --ui names)"
    xcrun simctl shutdown "$pro"
  fi
elif [ -z "$full" ]; then
  note "== G4 iPhone 17 Pro"
  device 17Pro "$pro"
  TEST_RUNNER_READSTAIR_PERF_STORE="$perf_store" cell "default-17Pro-PerformanceGateTests" "$pro" light default -only-testing:ReadStairUITests/PerformanceGateTests
  ! grep -hq ' skipped ' "$out"/ui/default-17Pro-PerformanceGateTests-a*.log || bad "a performance gate was skipped (no performance store?)"
  xcrun simctl io "$pro" recordVideo --codec h264 --force "$out/first-launch-17Pro.mp4" > /dev/null 2>&1 & rec=$!
  sleep 3; cell "recorded-17Pro-LaunchTests" "$pro" light default -only-testing:ReadStairUITests/LaunchTests
  kill -INT $rec 2>/dev/null; wait $rec 2>/dev/null
  xcrun simctl shutdown "$pro"
  note "== G5 iPhone SE"
  if [ -n "$se" ]; then device SE "$se"; xcrun simctl shutdown "$se"; else bad "no iPhone SE (3rd generation) simulator with iOS $ios"; fi
  note "== G6 iPad compatibility"
  if [ -n "$ipad" ]; then boot "$ipad"; cell "default-iPad-EndToEndTests" "$ipad" light default -only-testing:ReadStairUITests/EndToEndTests; xcrun simctl shutdown "$ipad"
  else bad "no iPad (A16) simulator with iOS $ios"; fi
fi

# Known-flaky failures get one isolated rerun, which must run exactly that test and pass; anything else stays a failure
if [ ${#failures[@]} -gt 0 ]; then
  note "== reruns"
  for f in "${failures[@]}"; do
    IFS='|' read -r failed_in udid appearance size test <<< "$f"
    case " $known_flaky " in
      *" ${test#*/} "*)
        boot "$udid"; name="rerun-$failed_in-${test#*/}"
        if TEST_RUNNER_READSTAIR_PERF_STORE="$perf_store" cell "$name" "$udid" "$appearance" "$size" \
          "-only-testing:ReadStairUITests/$test" && grep -hq 'Executed 1 test, with 0 failures' "$last_log"; then
          note "UI $test ($failed_in): known flaky, passed alone"
        else bad "UI $test ($failed_in) failed again alone"; fi
        xcrun simctl shutdown "$udid";;
      *) bad "UI $test ($failed_in) failed and is not on the known-flaky list";;
    esac
  done
fi

# G7 close
note "== G7"
[ "$(git rev-parse 'HEAD^{tree}')" = "$t0" ] && good "tree unchanged" || bad "the tree changed during the test"
[ -z "$(git status --porcelain)" ] && good "still no changes" || bad "the export has changes"
[ -z "$(ignored)" ] && good "ignored files still within the allowlist" || bad "ignored files outside the allowlist: $(ignored | tr '\n' ' ')"
verdict=PASS; [ $problems = 0 ] || verdict=FAIL
if [ -n "$full" ]; then scope="short (cites $(basename "$full"))"
elif [ "$command" = next ]; then scope="next (since ${previous:-the first release}; core: ${core:-none}; UI: ${ui[*]:-none})"
else scope=full; fi
{
  echo "# Release test · $(date +%F) · ReadStair $version (build $build)"
  echo
  echo "Command: $command"
  echo "Version: $version"
  echo "Build: $build"
  echo "REL: ${rel:-unknown}"
  if [ "$role" = publish ]; then echo "Candidate: $(git rev-parse HEAD)"; else echo "Candidate: worktree ${export_dir#"$dev"/}"; fi
  echo "Tree: $t0"
  echo "Scope: $scope"
  echo "Verdict: $verdict"
  echo "Package: pending"
  echo "TestFlight: pending"
  [ "$scope" = full ] && echo "Manual: pending (SE grid screenshots at .xxLarge and .xxxLarge; the real file picker, on the phone with TestFlight)"
  if [ "$command" = next ] && [ -n "$previous" ]; then echo; echo "Changed since $previous:"; git -C "$dev" diff --stat "$previous" "$rel" | tail -30; fi
  echo
  echo "Duration: $(( ($(date +%s) - start) / 60 )) min"
  echo
  echo '```'
  cat "$out/status.txt"
  echo '```'
} > "$out/record.md"
if [ "$verdict" = PASS ]; then
  if [ -f "$dev/Config/Local.xcconfig" ]; then
    cp "$dev/Config/Local.xcconfig" Config/Local.xcconfig && note "ready to archive: Local.xcconfig copied in"
  else
    note "NOT ready to archive: the development repository has no Config/Local.xcconfig to sign with"
  fi
fi
note "Verdict: $verdict ($problems problems) $(date '+%F %T')"
[ "$verdict" = PASS ]
