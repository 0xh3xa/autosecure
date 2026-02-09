#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/vincentkoc/autosecure}"

mapfile -t TAGS < <(git tag --sort=version:refname)

echo "# Changelog"
echo

if [ "${#TAGS[@]}" -eq 0 ]; then
  echo "No tags found."
  exit 0
fi

last_tag="${TAGS[-1]}"
unreleased="$(git log --pretty=format:'- %s (%h)' "${last_tag}..HEAD" || true)"
if [ -n "$unreleased" ]; then
  echo "## Unreleased"
  echo
  echo "$unreleased"
  echo
fi

for ((i=${#TAGS[@]}-1; i>=0; i--)); do
  tag="${TAGS[i]}"
  prev=""
  if [ "$i" -gt 0 ]; then
    prev="${TAGS[i-1]}"
    range="${prev}..${tag}"
  else
    range="${tag}"
  fi

  echo "## ${tag}"
  echo
  commits="$(git log --pretty=format:'- %s (%h)' "${range}" || true)"
  if [ -n "$commits" ]; then
    echo "$commits"
  else
    echo "- No changes"
  fi
  echo

  if [ -n "$prev" ]; then
    echo "Full Changelog: ${REPO_URL}/compare/${prev}...${tag}"
  else
    echo "Full Changelog: ${REPO_URL}/tree/${tag}"
  fi
  echo
 done
