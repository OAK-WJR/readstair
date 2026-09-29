#!/bin/bash
# Maintainers only: release exports. Run from the development repository; relative paths are relative to its top folder.
#   export-release.sh REL --worktree DIR
#       an upload that is not published here: a detached worktree of REL at DIR, a new git-ignored path, where the release
#       test (release-gate.sh next or minor) and the archive run
#   export-release.sh REL RELEASE_REPO [--init 'NAME <EMAIL>']
#       a published release: a new, unpushed commit of REL's exact tree in the separate release repository, tested with
#       release-gate.sh major (--init creates the repository the first time, with the public identity its commits carry);
#       refused once the version has its tag v<version>, or while an approved version was never published
#   export-release.sh --approve RELEASE_REPO RECORD
#       after the release test, the package check and TestFlight passed, as RECORD shows: tag the one commit the pre-push hook
#       may publish v<version>, record it, and print what will become public
# Both exports tag REL in the development repository as release/<version>-b<build>, the base the next release is compared with.
# The release repository never fetches from, clones or names the development repository: files reach it only as
# `git archive REL | tar -x`, followed by the check that its index then writes exactly REL's tree. Its commits and tags carry
# its readstair.identity setting and Pacific time, never the machine's git identity. A tag is never moved or deleted here.
set -euo pipefail
public_url='https://github.com/OAK-WJR/readstair.git'
fail() { echo "export-release: $*" >&2; exit 1; }
dev=$(git rev-parse --show-toplevel)
cd "$dev"
[ "$(git config --get readstair.role || true)" != publish ] || fail "run this from the development repository"

# MARKETING_VERSION and CURRENT_PROJECT_VERSION of REL, checked; fails if the release tag already names another commit
version_of() {
  local rel=$1 version build tag
  version=$(git show "$rel:Config/Shared.xcconfig" | sed -n 's/^MARKETING_VERSION = //p')
  build=$(git show "$rel:Config/Shared.xcconfig" | sed -n 's/^CURRENT_PROJECT_VERSION = //p')
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION '$version' is not x.y.z"
  [[ $build =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION '$build' is not a number"
  tag=release/$version-b$build
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [ "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse "$rel^{commit}")" ] || fail "$tag already names another commit"
  fi
  echo "$version $build"
}
tag_release() { git tag "release/$2-b$3" "$1" 2>/dev/null || git rev-parse -q --verify "refs/tags/release/$2-b$3" >/dev/null; }

# The public identity, "NAME <EMAIL>", from the release repository's own setting; no fallback to any other identity
valid_identity() { [[ $1 =~ ^[^\<\>]+\ \<[^\<\>\ ]+@[^\<\>\ ]+\>$ ]]; }
identity_of() {
  local id
  id=$(git -C "$1" config --get readstair.identity) || fail "$1 has no readstair.identity"
  valid_identity "$id" || fail "readstair.identity is not 'NAME <EMAIL>'"
  echo "$id"
}

# The isolation proof: the release repository holds one line of history, all by the public identity, and nothing of this one
verify() {
  local repo=$1 id refs tags roots merges people root
  id=$(identity_of "$repo")
  for f in objects/info/alternates shallow info/grafts; do [ ! -e "$repo/.git/$f" ] || fail "$f exists in the release repository"; done
  [ -z "$(git -C "$repo" for-each-ref refs/replace)" ] || fail "replace refs exist"
  refs=$(git -C "$repo" for-each-ref --format='%(refname)' | grep -vxE 'refs/heads/main|refs/remotes/origin/(main|HEAD)|refs/tags/v[0-9]+\.[0-9]+\.[0-9]+' || true)
  [ -z "$refs" ] || fail "unexpected refs in the release repository: $refs"
  tags=$(git -C "$repo" for-each-ref --format='%(objecttype) %(taggername) %(taggeremail)' refs/tags | sort -u)
  [ -z "$tags" ] || [ "$tags" = "tag $id" ] || fail "a tag in the release repository is not annotated by the public identity"
  roots=$(git -C "$repo" rev-list --max-parents=0 --all)
  [ "$(printf '%s\n' "$roots" | wc -l | tr -d ' ')" = 1 ] || fail "the release repository has more than one root commit"
  merges=$(git -C "$repo" rev-list --min-parents=2 --all)
  [ -z "$merges" ] || fail "a commit in the release repository has more than one parent"
  people=$(git -C "$repo" log --all --format='%an <%ae>|%cn <%ce>' | sort -u)
  [ "$people" = "$id|$id" ] || fail "a commit in the release repository is not by the public identity"
  for root in $(git rev-list --max-parents=0 --all); do
    ! git -C "$repo" cat-file -e "$root" 2>/dev/null || fail "a development commit is in the release repository"
  done
}
release_repo() { # the checks every use of the release repository starts with
  [ "$(git -C "$1" config --get readstair.role || true)" = publish ] || fail "$1 is not the release repository"
  [ "$(git -C "$1" remote)" = origin ] && [ "$(git -C "$1" remote get-url origin)" = "$public_url" ] \
    && [ "$(git -C "$1" remote get-url --push origin)" = "$public_url" ] || fail "$1 must have one remote, origin, fetching and pushing $public_url"
  [ -z "$(git -C "$1" status --porcelain)" ] || fail "$1 has changes"
}

if [ "${1:-}" = --approve ]; then
  [ $# = 3 ] || fail "usage: --approve RELEASE_REPO RECORD"
  repo=$2 record=$3
  release_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD) tree=$(git -C "$repo" rev-parse 'HEAD^{tree}')
  for line in 'Command: major' "Candidate: $head" "Tree: $tree" 'Verdict: PASS'; do
    grep -qxF -- "$line" "$record" || fail "the record lacks the line '$line'"
  done
  for field in Package TestFlight; do grep -qE "^$field: PASS( |$)" "$record" || fail "the record does not say '$field: PASS'"; done
  if git -C "$repo" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then new=$(git -C "$repo" rev-list --count origin/main..main)
  else new=$(git -C "$repo" rev-list --count main); fi
  [ "$new" = 1 ] || fail "a release adds exactly one commit; this would add $new"
  verify "$repo"
  # The version tag, annotated, by the public identity in Pacific time (git tag takes the tagger from the committer variables)
  version=$(git -C "$repo" show "$head:Config/Shared.xcconfig" | sed -n 's/^MARKETING_VERSION = //p')
  build=$(git -C "$repo" show "$head:Config/Shared.xcconfig" | sed -n 's/^CURRENT_PROJECT_VERSION = //p')
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION '$version' is not x.y.z"
  [ "$(git -C "$repo" log -1 --format=%s "$head")" = "ReadStair $version (build $build)" ] \
    || fail "the commit's title is not 'ReadStair $version (build $build)'"
  id=$(identity_of "$repo")
  if tagged=$(git -C "$repo" rev-parse -q --verify "refs/tags/v$version^{commit}"); then
    [ "$tagged" = "$head" ] || fail "v$version already names another commit, and a tag is never moved"
  else
    # Written byte for byte as the pre-push hook rebuilds it: the public identity, now in Pacific time, the fixed message
    when="$(date +%s) $(TZ=America/Los_Angeles date +%z)"
    sha=$(printf 'object %s\ntype commit\ntag v%s\ntagger %s %s\n\nReadStair %s\n' "$head" "$version" "$id" "$when" "$version" | git -C "$repo" mktag)
    git -C "$repo" update-ref "refs/tags/v$version" "$sha" ""
  fi
  # It must be exactly the object the pre-push hook rebuilds around the tag's own time, which must be Pacific
  when=$(git -C "$repo" cat-file tag "refs/tags/v$version" 2>/dev/null | sed -n '4s/^tagger .* \([0-9][0-9]* -0[78]00\)$/\1/p') || when=
  [ -n "$when" ] && [ "$(printf 'object %s\ntype commit\ntag v%s\ntagger %s %s\n\nReadStair %s\n' "$head" "$version" "$id" "$when" "$version" \
    | git hash-object -t tag --stdin)" = "$(git -C "$repo" rev-parse "refs/tags/v$version")" ] \
    || fail "v$version is not exactly the tag the pre-push hook accepts"
  verify "$repo"
  git -C "$repo" config readstair.approvedCommit "$head"
  echo "Approved $head, tagged v$version. This is what the push (git push --atomic origin main v$version) makes public:"
  git -C "$repo" for-each-ref --format='%(refname:short)  %(taggername) %(taggeremail)  %(taggerdate)  %(contents:subject)' "refs/tags/v$version"
  git -C "$repo" show --stat --format='%an <%ae>  %ad%n%n%B' "$head"
  exit 0
fi

[ $# -ge 2 ] || fail "usage: REL --worktree DIR | REL RELEASE_REPO [--init 'NAME <EMAIL>'] | --approve RELEASE_REPO RECORD"
rel=$(git rev-parse --verify "$1^{commit}")
[ -z "$(git status --porcelain)" ] || fail "the development repository has uncommitted changes"
! git cat-file -e "$rel:.gitattributes" 2>/dev/null || fail "REL has a .gitattributes, which would change exported files"
reltree=$(git rev-parse "$rel^{tree}")
vb=$(version_of "$rel")
read -r version build <<< "$vb"

if [ "$2" = --worktree ]; then
  [ $# = 3 ] || fail "usage: REL --worktree DIR"
  dir=$3
  [ ! -e "$dir" ] || fail "$dir already exists"
  git check-ignore -q "$dir" || fail "$dir is not a git-ignored path"
  git worktree add -q --detach "$dir" "$rel"
  [ "$(git -C "$dir" rev-parse 'HEAD^{tree}')" = "$reltree" ] || fail "the worktree is not REL's tree"
  tag_release "$rel" "$version" "$build" || fail "could not tag release/$version-b$build"
  echo "ReadStair $version (build $build): worktree $dir at $(git rev-parse --short "$rel"), tree $reltree"
  exit 0
fi

repo=$2
if [ "${3:-}" = --init ]; then
  [ $# = 4 ] || fail "usage: REL RELEASE_REPO --init 'NAME <EMAIL>'"
  valid_identity "$4" || fail "the identity must be 'NAME <EMAIL>'"
  [ ! -e "$repo" ] || fail "$repo already exists"
  git init -q -b main "$repo"
  git -C "$repo" config readstair.identity "$4"
  git -C "$repo" config core.hooksPath .githooks
  git -C "$repo" config readstair.role publish
  git -C "$repo" remote add origin "$public_url"
  git -C "$repo" config remote.origin.push refs/heads/main:refs/heads/main
  git -C "$repo" config branch.main.remote origin
  git -C "$repo" config branch.main.merge refs/heads/main
elif [ $# != 2 ]; then
  fail "usage: REL RELEASE_REPO [--init 'NAME <EMAIL>']"
fi
release_repo "$repo"
# A version tag off the public main waits unpublished, and a tagged version is done; a tag is never moved or deleted here,
# so in either case the author decides
for t in $(git -C "$repo" for-each-ref --format='%(refname)' 'refs/tags/v*'); do
  git -C "$repo" merge-base --is-ancestor "$t" refs/remotes/origin/main 2>/dev/null && continue
  what='was approved'
  [ "$(git -C "$repo" rev-parse "$t^{commit}")" = "$(git -C "$repo" config --get readstair.approvedCommit || true)" ] \
    || what='is tagged but not approved'
  fail "${t#refs/tags/} $what and was never published; ask the author (if it was pushed, run git -C $repo fetch origin first)"
done
! git -C "$repo" rev-parse -q --verify "refs/tags/v$version" >/dev/null \
  || fail "$version was approved and tagged v$version; tags are never moved or deleted here, so ask the author (a new version?)"
# The message: "ReadStair x.y.z (build N)", then REL's message body, checked by REL's own checker before anything here changes.
# It is published verbatim, and the checker skips lines starting with #, so there may be none.
terms="$(git rev-parse --path-format=absolute --git-common-dir)/info/private-terms"
[ -s "$terms" ] || fail "the development repository has no private terms"
mkdir -p "$repo/.git/info" && cp "$terms" "$repo/.git/info/private-terms"
msg=$(mktemp) checker=$(mktemp)
trap 'rm -f "$msg" "$checker"' EXIT
body=$(git log -1 --format=%b "$rel")
{ echo "ReadStair $version (build $build)"; [ -z "$body" ] || printf '\n%s\n' "$body"; } > "$msg"
! grep -q '^#' "$msg" || fail "REL's message has a line starting with #, which the privacy check skips"
git show "$rel:tools/check-secrets.sh" > "$checker"
(cd "$repo" && bash "$checker" --require-terms --message "$msg") >&2 || fail "the message failed the privacy check"
git -C "$repo" config --unset readstair.approvedCommit || true
id=$(identity_of "$repo")
name=${id% <*}
email=$(sed 's/.*<\(.*\)>$/\1/' <<< "$id")

# Files: the previous candidate's copy of the signing settings and build output go first, then REL's exact files
rm -f "$repo/Config/Local.xcconfig"
rm -rf "$repo/build" "$repo/Packages/ReadStairCore/.build" "$repo/Packages/ReadStairCore/.swiftpm"
git -C "$repo" rm -rq --ignore-unmatch --cached .
git -C "$repo" ls-files -z --others --exclude-standard | (cd "$repo" && xargs -0 rm -f --)
git archive "$rel" | tar -x -C "$repo"
git ls-tree -r -z --name-only "$rel" |
  git -C "$repo" -c core.autocrlf=false --literal-pathspecs add -f --pathspec-from-file=- --pathspec-file-nul
[ "$(git -C "$repo" write-tree)" = "$reltree" ] || fail "the release repository's files are not exactly REL's"
stray=$(git -C "$repo" ls-files --others --exclude-standard)
[ -z "$stray" ] || fail "files that are not REL's are in the release repository: $(head -3 <<< "$stray" | tr '\n' ' ')"
parent=()
if git -C "$repo" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then parent=(-p "$(git -C "$repo" rev-parse refs/remotes/origin/main)"); fi
new=$(env -u GIT_AUTHOR_DATE -u GIT_COMMITTER_DATE "GIT_AUTHOR_NAME=$name" "GIT_AUTHOR_EMAIL=$email" "GIT_COMMITTER_NAME=$name" \
  "GIT_COMMITTER_EMAIL=$email" TZ=America/Los_Angeles git -C "$repo" commit-tree "$reltree" ${parent[@]+"${parent[@]}"} -F "$msg")
old=$(git -C "$repo" rev-parse -q --verify refs/heads/main || true)
git -C "$repo" update-ref refs/heads/main "$new" "$old"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the release repository does not match its new commit"
verify "$repo"
tag_release "$rel" "$version" "$build" || fail "could not tag release/$version-b$build"
echo "ReadStair $version (build $build): candidate $(git -C "$repo" rev-parse --short "$new") in $repo, tree $reltree (not pushed)"
