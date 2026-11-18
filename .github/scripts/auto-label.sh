#!/usr/bin/env bash
# Auto-label an issue or pull request based on .github/auto-label.json.
# Designed for GitHub Actions: reads context from env vars, uses `gh api`.
set -euo pipefail

CONFIG="${CONFIG:-.github/auto-label.json}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
NUMBER="${ITEM_NUMBER:?ITEM_NUMBER is required}"
EVENT="${EVENT_NAME:-}"

for tool in jq gh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is required" >&2
    exit 1
  fi
done
if [[ ! -f "$CONFIG" ]]; then
  echo "::error::Config not found: $CONFIG" >&2
  exit 1
fi

CREATE_MISSING="$(jq -r '.settings.create_missing_labels // true' "$CONFIG")"

# ---------------------------------------------------------------- item text --
item_json="$(gh api "repos/$REPO/issues/$NUMBER")"
title="$(jq -r '.title // ""' <<<"$item_json")"
body="$(jq -r '.body // ""' <<<"$item_json")"
text_lc="$(printf '%s\n%s' "$title" "$body" | tr '[:upper:]' '[:lower:]')"

# ------------------------------------------------- changed files (PRs only) ---
files=()
if [[ "$EVENT" == pull_request* ]]; then
  file_list="$(gh api "repos/$REPO/pulls/$NUMBER/files" --paginate --jq '.[].filename')"
  while IFS= read -r f; do
    if [[ -n "$f" ]]; then
      files+=("$f")
    fi
  done <<<"$file_list"
fi

# --------------------------------------- labels already on the issue / PR -----
declare -A have=()
item_labels="$(gh api "repos/$REPO/issues/$NUMBER/labels" --paginate --jq '.[].name')"
while IFS= read -r l; do
  if [[ -n "$l" ]]; then
    have["$l"]=1
  fi
done <<<"$item_labels"

# -------------------------------------------- label catalog of the repository --
declare -A repo_labels=()
all_labels="$(gh api "repos/$REPO/labels" --paginate --jq '.[].name')"
while IFS= read -r l; do
  if [[ -n "$l" ]]; then
    repo_labels["$l"]=1
  fi
done <<<"$all_labels"

# --------------------------------------------------------- candidate labels ---
declare -A want=()
add() {
  if [[ -n "$1" ]]; then
    want["$1"]=1
  fi
}

# Defaults (e.g. tag every new issue as "triage").
default_key="pull_requests"
if [[ "$EVENT" == "issues" ]]; then
  default_key="issues"
fi
default_rows="$(jq -r ".defaults.$default_key[]?" "$CONFIG")"
while IFS= read -r l; do
  add "$l"
done <<<"$default_rows"

# Keyword rules against title + body.
keyword_rows="$(jq -r '.keyword_rules[]? | .label as $l | .keywords[] | [$l, .] | @tsv' "$CONFIG")"
while IFS=$'\t' read -r label kw; do
  if [[ -z "$label" || -z "$kw" ]]; then
    continue
  fi
  kw_lc="$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]')"
  if [[ "$text_lc" == *"$kw_lc"* ]]; then
    add "$label"
  fi
done <<<"$keyword_rows"

# Path rules against changed files (PRs only).
# In [[ ]] pattern matching, '*' also matches '/', so "drivers/*" covers nested dirs.
path_rows="$(jq -r '.path_rules[]? | .label as $l | .paths[] | [$l, .] | @tsv' "$CONFIG")"
if (( ${#files[@]} > 0 )); then
  while IFS=$'\t' read -r label pat; do
    if [[ -z "$label" || -z "$pat" ]]; then
      continue
    fi
    for f in "${files[@]}"; do
      # shellcheck disable=SC2053 -- glob expansion is intentional here
      if [[ "$f" == $pat ]]; then
        add "$label"
        break
      fi
    done
  done <<<"$path_rows"
fi

# ------------------------------------------------------------- apply labels ---
to_add=()
for label in "${!want[@]}"; do
  if [[ -n "${have[$label]:-}" ]]; then
    continue
  fi

  if [[ -z "${repo_labels[$label]:-}" ]]; then
    if [[ "$CREATE_MISSING" != "true" ]]; then
      echo "::warning::Label '$label' does not exist; skipping."
      continue
    fi
    color="$(jq -r --arg l "$label" '.labels[$l].color // "ededed"' "$CONFIG")"
    desc="$(jq -r --arg l "$label" '.labels[$l].description // ""' "$CONFIG")"
    gh api "repos/$REPO/labels" \
      -f name="$label" -f color="$color" -f description="$desc" >/dev/null
    repo_labels["$label"]=1
    echo "Created label: $label"
  fi

  to_add+=("$label")
done

if (( ${#to_add[@]} > 0 )); then
  # -F with "labels[]=..." builds a JSON array for the REST endpoint.
  label_args=()
  for l in "${to_add[@]}"; do
    label_args+=("-F" "labels[]=$l")
  done
  gh api "repos/$REPO/issues/$NUMBER/labels" "${label_args[@]}" >/dev/null
  printf 'Applied labels: %s\n' "${to_add[*]}"
else
  echo "No new labels to apply."
fi
