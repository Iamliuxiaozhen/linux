#!/usr/bin/env bash
#
# Check DCO (Developer Certificate of Origin) sign-offs in a commit range.
# Rule: every non-merge commit must carry a Signed-off-by trailer whose name
# and email match the commit author.
#
# Usage: check-dco.sh <base-sha> <head-sha>

set -euo pipefail

base="${1:-}"
head="${2:-}"

if [[ -z "$base" || -z "$head" ]]; then
	echo "Usage: $0 <base-sha> <head-sha>" >&2
	exit 2
fi

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
	echo "::error::Base commit $base not found; make sure it was fetched" >&2
	exit 2
fi
if ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
	echo "::error::Head commit $head not found; make sure it was fetched" >&2
	exit 2
fi

# Use temporary files instead of process substitution: /dev/fd is not
# mounted in some environments.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
commits="$workdir/commits"
signoffs="$workdir/signoffs"
git rev-list --no-merges "$base..$head" > "$commits"

total=0
bad=0

while IFS= read -r sha; do
	[[ -z "$sha" ]] && continue
	total=$((total + 1))

	author_name="$(git show -s --format='%an' "$sha")"
	author_email="$(git show -s --format='%ae' "$sha")"
	git show -s --format='%B' "$sha" | grep -i '^Signed-off-by:' > "$signoffs" || true

	signed=0
	while IFS= read -r line; do
		# Format: "Signed-off-by: Name <mail@example.com>"
		value="${line#*:}"
		signer_mail="$(printf '%s' "$value" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
		signer_name="$(printf '%s' "$value" | sed -n 's/\(.*\)<.*/\1/p' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
		if [[ "${signer_mail,,}" == "${author_email,,}" && "${signer_name,,}" == "${author_name,,}" ]]; then
			signed=1
			break
		fi
	done < "$signoffs"

	if [[ "$signed" -eq 0 ]]; then
		echo "::error file=.git::Commit ${sha:0:12} is missing a valid sign-off (author: $author_name <$author_email>)"
		bad=$((bad + 1))
	fi
done < "$commits"

if [[ "$bad" -ne 0 ]]; then
	echo "::error::DCO check failed: $bad/$total commits are missing a matching Signed-off-by"
	exit 1
fi

echo "DCO check passed: all $total commits are properly signed off."
