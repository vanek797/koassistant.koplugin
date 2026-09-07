#!/bin/sh
# Release-notes gap check: commits since the last v* tag that the running
# release-notes draft does not cite in its "<!-- covered: h1 h2 ... -->" trailer.
# A commit is cited once its user-visible change has a bullet in the draft, or
# once it has been judged internal (cite those too, so the list stays empty).
# Usage: tests/tools/release_gap.sh [docs/release_notes_vX.Y.Z.md]
set -eu
cd "$(dirname "$0")/../.."
draft=${1:-$(ls docs/release_notes_v*.md | sort -V | tail -n 1)}
tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*')
covered=$(sed -n 's/.*<!-- covered:\(.*\)-->.*/\1/p' "$draft" | tr '\n' ' ')
total=$(git rev-list --count "$tag..HEAD")
missing=0
for h in $(git log --abbrev=7 --format=%h "$tag..HEAD"); do
    case " $covered " in
        *" $h "*) ;;
        *) missing=$((missing + 1)); git log -1 --abbrev=7 --format='  %h %ad %s' --date=short "$h" ;;
    esac
done
echo "$draft: $missing of $total commits since $tag not cited in the covered trailer"
[ "$missing" -eq 0 ]
