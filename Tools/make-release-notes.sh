#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  echo "usage: Tools/make-release-notes.sh <version> <notes.md> <notes.html>" >&2
  exit 1
fi
version=$1 md=$2 html=$3
root=${0:A:h:h}

# The "## [<version>]" section of CHANGELOG.md without its heading, up to the next section or the
# link list. Each list item goes on one line, as a release shows every line break it is given.
awk -v heading="## [$version]" '
  function out(line) {
    if (line ~ /^[[:space:]]*$/) { if (printed) blank = 1; return }
    if (blank) print ""
    print line
    printed = 1; blank = 0
  }
  index($0, heading) == 1 { found = 1; next }
  !found { next }
  /^## / || /^\[[^]]+\]: / { exit }
  /^[[:space:]]*$/ { out(item); item = ""; out(""); next }
  /^#/ || /^[[:space:]]*([-*+]|[0-9]+\.) / { out(item); item = $0; next }
  { sub(/^[[:space:]]+/, ""); item = item == "" ? $0 : item " " $0 }
  END { out(item) }
' "$root/CHANGELOG.md" > "$md"
if [[ ! -s "$md" ]]; then
  echo "CHANGELOG.md has no section for $version" >&2
  exit 1
fi

gh api markdown -f mode=gfm -f context=MushkyQT/SlyTerm -F text=@"$md" > "$html"
echo "Wrote $md and $html"
